import Photos
import SwiftUI

/// 한클립의 날짜 다중 선택을 사진 탭과 동일한 PHAsset 바스켓에 바로 연결한다.
struct LocalPhotoLibraryCalendarView: View {
    let selectedIdentifiers: Set<String>
    let onToggle: (PHAsset) -> Void
    let onAdd: ([PHAsset]) -> Void
    let onRemove: ([PHAsset]) -> Void
    let onRemoveDates: (Set<Date>) -> Void
    let onPreview: (PHAsset) -> Void
    let onRequestPhotoMode: () -> Void

    @State private var authorizationStatus = LocalPhotoLibraryCalendarService.authorizationStatus
    @State private var visibleMonth = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDates: Set<Date> = []
    @State private var selectedAssets: [PHAsset] = []
    @State private var calendarAssets: [PHAsset] = []
    @State private var didRestoreSelection = false
    @State private var mediaCountsByDate: [Date: Int] = [:]
    @State private var holidayNamesByDate: [Date: String] = [:]
    @State private var loadedMonth: Date?
    @State private var isLoadingMonth = false
    @State private var monthLoadProgress = 0.0
    @State private var showMonthYearPicker = false
    @State private var draftYear = Calendar.current.component(.year, from: Date())
    @State private var draftMonth = Calendar.current.component(.month, from: Date())
    @State private var queryGeneration = 0
    @State private var dateTask: Task<Void, Never>?
    @State private var daySelectionTasks: [Date: Task<Void, Never>] = [:]
    @State private var isFindingDate = false
    @State private var columnCount = 6
    @State private var magnificationCheckpoint: CGFloat = 1
    @State private var scrollButtonsVisible = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var hideScrollButtonsTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    private let calendar = Calendar.current
    private let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let columnSteps = [8, 6, 4, 2, 1]

    var body: some View {
        Group {
            switch authorizationStatus {
            case .authorized, .limited: calendarContent
            case .notDetermined: notDeterminedContent
            default: deniedContent
            }
        }
        .task(id: selectedIdentifiers) { await reloadSharedSelection() }
        .task(id: selectedDates) { await reloadCalendarAssets() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            authorizationStatus = LocalPhotoLibraryCalendarService.authorizationStatus
            invalidateCalendarCaches()
        }
        .onAppear { isFindingDate = false }
        .onDisappear {
            dateTask?.cancel()
            daySelectionTasks.values.forEach { $0.cancel() }
            daySelectionTasks = [:]
            hideScrollButtonsTask?.cancel()
        }
    }
    private var notDeterminedContent: some View {
        ContentUnavailableView {
            Label("달력에서 사진 보기", systemImage: "calendar")
        } description: {
            Text("날짜별로 사진과 영상을 확인하려면 사진 보관함 접근을 허용해 주세요. 달력은 사진 보관함에서 허용한 항목을 표시합니다.")
        } actions: {
            Button("접근 허용") {
                Task {
                    let status = await LocalPhotoLibraryCalendarService.requestAccess()
                    authorizationStatus = status
                }
            }
            .buttonStyle(.borderedProminent)
            Button("사진으로 선택", action: onRequestPhotoMode)
        }
    }

    private var deniedContent: some View {
        ContentUnavailableView {
            Label("사진 보관함 접근이 꺼져 있습니다", systemImage: "lock")
        } description: {
            Text("설정 앱에서 사진 보관함 접근을 허용하면 달력으로 사진을 찾을 수 있습니다.")
        } actions: {
            Button("설정에서 사진 접근 확인") {
                #if targetEnvironment(macCatalyst)
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!
                #else
                let url = URL(string: UIApplication.openSettingsURLString)!
                #endif
                UIApplication.shared.open(url)
            }
            Button("사진으로 선택", action: onRequestPhotoMode)
                .buttonStyle(.borderedProminent)
        }
    }

    private var limitedAccessBanner: some View {
        HStack {
            Text("일부 사진만 보입니다")
                .font(.ui(.footnote))
                .foregroundStyle(.secondary)
            Spacer()
            Button("선택 변경") {
                presentLimitedLibraryPicker()
            }
            .font(.ui(.footnote))
        }
        .padding(.horizontal, ui(12))
        .padding(.vertical, ui(6))
        .background(.bar)
    }

    private var monthYearPicker: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("연도", selection: $draftYear) {
                    ForEach((currentYear - 30)...(currentYear + 10), id: \.self) { year in
                        Text("\(year)년").tag(year)
                    }
                }
                .pickerStyle(.wheel)
                Picker("월", selection: $draftMonth) {
                    ForEach(1...12, id: \.self) { month in
                        Text("\(month)월").tag(month)
                    }
                }
                .pickerStyle(.wheel)
            }
            .navigationTitle("년 월 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { showMonthYearPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("이동") {
                        if let month = calendar.date(from: DateComponents(year: draftYear, month: draftMonth)) {
                            visibleMonth = calendar.startOfMonth(for: month)
                        }
                        showMonthYearPicker = false
                    }
                }
            }
        }
    }

    private var monthCells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth))
        else { return [] }
        let leadingEmptyCount = calendar.component(.weekday, from: firstDay) - 1
        let dates = range.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
        let totalCells = Int(ceil(Double(leadingEmptyCount + dates.count) / 7.0)) * 7
        let cells = Array(repeating: nil, count: leadingEmptyCount) + dates
        return cells + Array(repeating: nil, count: max(0, totalCells - cells.count))
    }


    private var calendarContent: some View {
        VStack(spacing: 0) {
            if authorizationStatus == .limited { limitedAccessBanner }
            monthControls.padding(.top, ui(6))
            calendarTable.padding(.horizontal, ui(12)).padding(.top, ui(4))
            HStack(spacing: 0) {
                HStack(spacing: ui(4)) {
                    Text("선택 \(selectedDates.count)일 · 미디어 \(selectedAssets.count)개")
                        .font(.system(size: ui(13), weight: .semibold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    if isFindingDate {
                        ProgressView().controlSize(.small).frame(width: ui(16), height: ui(16))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: ui(8))
                HStack(spacing: ui(8)) {
                    Button { selectPreviousMediaDay() } label: {
                        Text("전날").frame(width: ui(44), height: ui(44)).contentShape(Rectangle())
                    }
                    Button { selectToday() } label: {
                        Text("오늘").frame(width: ui(44), height: ui(44)).contentShape(Rectangle())
                    }
                    Button { clearSelection() } label: {
                        Text("해제").frame(width: ui(44), height: ui(44)).contentShape(Rectangle())
                    }
                        .disabled(selectedDates.isEmpty && selectedAssets.isEmpty)
                }
                .font(.system(size: ui(13), weight: .regular))
                .foregroundStyle(SkyBreezeTheme.accent)
                .buttonStyle(.plain)
            }
            .frame(height: ui(44))
            .padding(.horizontal, ui(12))
            selectedThumbnailGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: visibleMonth) { await loadMediaCounts() }
        .sheet(isPresented: $showMonthYearPicker) { monthYearPicker }
    }
    private var monthControls: some View {
        HStack {
            Button { moveMonth(by: -1) } label: { Image(systemName: "chevron.left").frame(width: ui(40), height: ui(36)) }
                .accessibilityLabel("이전 달")
            Spacer()
            Button {
                draftYear = calendar.component(.year, from: visibleMonth)
                draftMonth = calendar.component(.month, from: visibleMonth)
                showMonthYearPicker = true
            } label: {
                VStack(spacing: ui(2)) {
                    Text(monthTitle).font(.ui(.headline))
                    if isLoadingMonth { ProgressView(value: monthLoadProgress, total: 1).frame(width: ui(110)) }
                }
            }.accessibilityHint("연도와 월을 선택해 이동합니다.")
            Spacer()
            Button { moveMonth(by: 1) } label: { Image(systemName: "chevron.right").frame(width: ui(40), height: ui(36)) }
                .accessibilityLabel("다음 달")
        }.padding(.horizontal, ui(12))
    }
    private var currentYear: Int { calendar.component(.year, from: Date()) }
    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월"
        return formatter.string(from: visibleMonth)
    }
    private var calendarTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { index, weekday in
                    Text(weekday).font(.ui(.caption))
                        .foregroundStyle(index == 0 ? Color.red : index == 6 ? Color.blue : Color.secondary)
                        .frame(maxWidth: .infinity).frame(height: ui(22))
                }
            }
            LazyVGrid(columns: columns, spacing: ui(1)) {
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                    if let date { dayCell(for: date) }
                    else { Color.clear.frame(height: ui(38)) }
                }
            }
        }
    }
    private func dayCell(for date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let count = mediaCountsByDate[day] ?? 0
        let selected = selectedDates.contains(day)
        let today = calendar.isDateInToday(day)
        let holiday = holidayNamesByDate[day]
        let weekday = calendar.component(.weekday, from: day)
        let textColor: Color = holiday != nil || weekday == 1 ? .red : weekday == 7 ? .blue : .primary
        return Button { toggleDate(day) } label: {
            VStack(spacing: 0) {
                HStack(spacing: ui(2)) {
                    Text("\(calendar.component(.day, from: day))").font(.ui(.subheadline).weight(today ? .bold : .regular))
                    if count > 0 { Text("\(count)").font(.ui(.caption2)).foregroundStyle(.secondary) }
                }
                if let holiday {
                    Text(holiday).font(.system(size: ui(8))).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity).frame(height: ui(38))
            .background {
                RoundedRectangle(cornerRadius: ui(7))
                    .fill(selected ? Color.accentColor.opacity(0.23) : count > 0 ? Color.secondary.opacity(0.08) : Color.clear)
            }
            .overlay {
                if today { RoundedRectangle(cornerRadius: ui(7)).stroke(Color.accentColor, lineWidth: ui(1.5)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(count == 0)
        .accessibilityLabel(["\(calendar.component(.day, from: day))일", holiday, "미디어 \(count)개"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var selectedThumbnailGrid: some View {
        GeometryReader { geometry in
            let spacing = ui(4)
            let width = max(ui(1), geometry.size.width - ui(24))
            let size = max(ui(1), (width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            let rowCount = Int(ceil(Double(calendarAssets.count) / Double(columnCount)))
            let contentHeight = CGFloat(rowCount) * (size + spacing)
            let canScroll = contentHeight > geometry.size.height
            ScrollViewReader { proxy in
                ZStack(alignment: .trailing) {
                    ScrollView {
                        Color.clear.frame(height: 1).id("calendarTop")
                            .background {
                                GeometryReader { position in
                                    Color.clear.preference(key: NasFinderCalendarScrollOffsetKey.self,
                                        value: position.frame(in: .named("nasfinderCalendarThumbnails")).minY)
                                }
                            }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: spacing), count: columnCount), spacing: spacing) {
                            ForEach(calendarAssets, id: \.localIdentifier) { asset in
                                let isSelected = selectedIdentifiers.contains(asset.localIdentifier)
                                LocalPhotoLibraryAssetCell(asset: asset, isSelected: isSelected,
                                    onToggle: { toggleAssetSelection(asset) }, size: size, showsSelectionIndicator: false)
                                    .highPriorityGesture(
                                        LongPressGesture(minimumDuration: 0.45, maximumDistance: 10)
                                            .exclusively(before: TapGesture())
                                            .onEnded { gesture in
                                                switch gesture {
                                                case .first: onPreview(asset)
                                                case .second: toggleAssetSelection(asset)
                                                }
                                            }
                                    )
                                    .accessibilityAction(named: "미리보기") { onPreview(asset) }
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: ui(17), weight: .semibold))
                                            .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.4))
                                            .frame(width: ui(44), height: ui(44))
                                            .allowsHitTesting(false)
                                            .accessibilityHidden(true)
                                    }
                            }
                        }.padding(.horizontal, ui(12))
                        Color.clear.frame(height: 1).id("calendarBottom")
                    }
                    .coordinateSpace(name: "nasfinderCalendarThumbnails")
                    .onPreferenceChange(NasFinderCalendarScrollOffsetKey.self) { offset in
                        let changed = abs(offset - lastScrollOffset) > 0.5
                        lastScrollOffset = offset
                        if canScroll && changed { showScrollButtons(); scheduleScrollButtonsHide() }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 1)
                        .onChanged { _ in if canScroll { showScrollButtons() } }
                        .onEnded { _ in scheduleScrollButtonsHide() })
                    if calendarAssets.isEmpty {
                        ContentUnavailableView("날짜를 선택하세요", systemImage: "calendar", description: Text("여러 날짜를 선택하거나 전날·오늘로 사진과 영상을 모을 수 있습니다."))
                    }
                    if canScroll && scrollButtonsVisible {
                        VStack {
                            Button { withAnimation { proxy.scrollTo("calendarTop", anchor: .top) } } label: {
                                Image(systemName: "chevron.up.circle.fill").font(.ui(.title)).padding(ui(6))
                            }
                            Spacer()
                            Button { withAnimation { proxy.scrollTo("calendarBottom", anchor: .bottom) } } label: {
                                Image(systemName: "chevron.down.circle.fill").font(.ui(.title)).padding(ui(6))
                            }
                        }.padding(ui(4)).transition(.opacity)
                    }
                }
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { updateColumns($0) }
                    .onEnded { _ in magnificationCheckpoint = 1 })
            }
        }
    }
    private func updateColumns(_ magnification: CGFloat) {
        guard let index = columnSteps.firstIndex(of: columnCount) else { return }
        let relative = magnification / magnificationCheckpoint
        if relative > 1.35 {
            columnCount = columnSteps[min(index + 1, columnSteps.count - 1)]
            magnificationCheckpoint = magnification
        } else if relative < 0.65 {
            columnCount = columnSteps[max(index - 1, 0)]
            magnificationCheckpoint = magnification
        }
    }
    private func showScrollButtons() {
        hideScrollButtonsTask?.cancel()
        withAnimation { scrollButtonsVisible = true }
    }
    private func scheduleScrollButtonsHide() {
        hideScrollButtonsTask?.cancel()
        hideScrollButtonsTask = Task {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            withAnimation { scrollButtonsVisible = false }
        }
    }
    private func toggleAssetSelection(_ asset: PHAsset) {
        let wasSelected = selectedIdentifiers.contains(asset.localIdentifier)
        onToggle(asset)
        if wasSelected {
            selectedAssets.removeAll { $0.localIdentifier == asset.localIdentifier }
        } else if !selectedAssets.contains(where: { $0.localIdentifier == asset.localIdentifier }) {
            selectedAssets.append(asset)
        }
        // 마지막 항목을 해제해도 날짜와 썸네일은 유지하여 다시 체크할 수 있게 한다.
    }
    private func reloadCalendarAssets() async {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        let dates = selectedDates
        let assets = await Task.detached {
            dates.sorted().flatMap { LocalPhotoLibraryCalendarService.assets(on: $0, calendar: Calendar.current) }
        }.value
        guard !Task.isCancelled, selectedDates == dates else { return }
        calendarAssets = assets
    }
    private func toggleDate(_ day: Date) {
        if selectedDates.contains(day) {
            daySelectionTasks[day]?.cancel()
            daySelectionTasks.removeValue(forKey: day)
            selectedDates.remove(day)
            onRemoveDates([day])
            selectedAssets.removeAll { $0.creationDate.map { calendar.startOfDay(for: $0) == day } == true }
        } else { selectDate(day) }
    }
    private func selectDate(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        selectedDates.insert(day)
        visibleMonth = calendar.startOfMonth(for: day)
        daySelectionTasks[day]?.cancel()
        daySelectionTasks[day] = Task {
            let assets = await Task.detached {
                LocalPhotoLibraryCalendarService.assets(on: day, calendar: Calendar.current)
            }.value
            guard !Task.isCancelled, selectedDates.contains(day) else { return }
            onAdd(assets)
            daySelectionTasks.removeValue(forKey: day)
        }
    }
    private func selectToday() {
        let today = calendar.startOfDay(for: Date())
        let month = calendar.startOfMonth(for: today)
        if !calendar.isDate(visibleMonth, equalTo: month, toGranularity: .month) { visibleMonth = month; return }
        if (mediaCountsByDate[today] ?? 0) > 0 { selectDate(today) }
    }
    private func selectPreviousMediaDay() {
        dateTask?.cancel()
        isFindingDate = true
        let first = selectedDates.min()
        dateTask = Task {
            let date = await Task.detached {
                if let first {
                    return LocalPhotoLibraryCalendarService.previousMediaDate(before: first, calendar: Calendar.current)
                }
                let calendar = Calendar.current
                let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
                return LocalPhotoLibraryCalendarService.closestMediaDate(to: yesterday, calendar: calendar)
            }.value
            guard !Task.isCancelled else { return }
            isFindingDate = false
            if let date { selectDate(date) }
        }
    }
    private func clearSelection() {
        dateTask?.cancel()
        isFindingDate = false
        daySelectionTasks.values.forEach { $0.cancel() }
        daySelectionTasks = [:]
        onRemoveDates(selectedDates)
        selectedDates.removeAll()
        onRemove(selectedAssets)
        selectedAssets = []
    }
    private func reloadSharedSelection() async {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        let ids = Array(selectedIdentifiers)
        let assets = await Task.detached {
            LocalPhotoLibraryCalendarService.assets(withIdentifiers: ids)
        }.value
        guard !Task.isCancelled else { return }
        selectedAssets = assets
        let dates = Set(assets.compactMap { $0.creationDate.map { calendar.startOfDay(for: $0) } })
        if !didRestoreSelection {
            selectedDates = dates
            didRestoreSelection = true
        } else { selectedDates.formUnion(dates) }
    }
    private func moveMonth(by value: Int) {
        if let month = calendar.date(byAdding: .month, value: value, to: visibleMonth) { visibleMonth = calendar.startOfMonth(for: month) }
    }
    @MainActor private func loadMediaCounts() async {
        let month = visibleMonth
        let year = calendar.component(.year, from: month)
        let generation = queryGeneration
        holidayNamesByDate = NasFinderKoreanHolidayService.cachedHolidayNames(for: year, calendar: calendar)
        if loadedMonth != month {
            isLoadingMonth = true
            monthLoadProgress = 0
            let counts = await Task.detached {
                LocalPhotoLibraryCalendarService.mediaCounts(in: month, calendar: Calendar.current) { progress in
                    guard generation == queryGeneration else { return }
                    monthLoadProgress = progress
                }
            }.value
            guard !Task.isCancelled, generation == queryGeneration, visibleMonth == month else { return }
            mediaCountsByDate.merge(counts) { _, new in new }
            loadedMonth = month
            monthLoadProgress = 1
            isLoadingMonth = false
        }
        let holidays = await NasFinderKoreanHolidayService.refreshedHolidayNames(for: year, calendar: calendar)
        guard !Task.isCancelled, calendar.component(.year, from: visibleMonth) == year else { return }
        holidayNamesByDate = holidays
    }
    private func presentLimitedLibraryPicker() {
        guard let rootViewController = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        else { return }
        // `presentLimitedLibraryPicker(from:)` dismisses without any callback, so waiting
        // for the next `scenePhase` transition is the only way to know the user is done.
        // The completion-handler overload fires as soon as the sheet is dismissed (the
        // app is still foregrounded), so invalidate right there instead of waiting on
        // scenePhase, which may not change at all if the app never left the foreground.
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: rootViewController) { _ in
            Task { @MainActor in
                authorizationStatus = LocalPhotoLibraryCalendarService.authorizationStatus
                invalidateCalendarCaches()
            }
        }
    }

    private func invalidateCalendarCaches() {
        queryGeneration += 1
        loadedMonth = nil
        Task {
            await loadMediaCounts()
            await reloadSharedSelection()
            await reloadCalendarAssets()
        }
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}

private struct NasFinderCalendarScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
