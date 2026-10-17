# Third-party components used by optional HanAI media adapters

HanAI's Foundation-only Swift and Kotlin decision core does not require these optional inference runtimes. Include the relevant complete license documents with every model/runtime distribution and consuming app.

## DINOv2-small model

- Source: https://huggingface.co/facebook/dinov2-small/tree/ed25f3a31f01632728cabb09d1542f84ab7b0056
- Original authors: Meta Platforms, Inc. and affiliates; Hugging Face conversion/model card attribution is retained in the source card.
- Code and model weights: Apache License 2.0. See [license](licenses/dinov2/LICENSE) and [original model card](licenses/dinov2/MODEL_CARD.md).
- HanAI modified exports: ONNX/Core ML format conversion, fixed 224×224 tensor input, CLS-token extraction and L2 normalization. The Core ML export additionally precomputes the source model's original positional interpolation at that fixed size. This conversion does not fine-tune the source weights. HanAI's changes are not endorsed by Meta or Hugging Face.
- Provenance, source SHA256, precision and preprocessing are supplied beside the model artifact. The source repository did not contain an original DINOv2 NOTICE file; this document is HanAI's own distribution notice.

## ONNX Runtime 1.24.2

Copyright (c) Microsoft Corporation. MIT License; preserve the [full license](licenses/onnxruntime-1.24.2/LICENSE) and the unmodified [ThirdPartyNotices](licenses/onnxruntime-1.24.2/ThirdPartyNotices.txt). An Android AAR dependency alone does not provide an in-app license screen. Consuming apps must include accessible copies with the shipped runtime.

## RGB preprocessing compatibility

The Swift/Kotlin resampling implementations follow the RGB8 bicubic arithmetic of Pillow 12.3.0, commit bb1d8e8ab8d29048624d96e3ee53cecf7c13d13d, and the rescale/normalization contract of Hugging Face Transformers 5.20.1, commit 0ea877911a11499053df677befd4b35b172ff502. They are compatibility implementations, not a claim of endorsement. Preserve [Pillow's complete MIT-CMU copyright/permission notice](licenses/pillow-12.3.0/LICENSE) and [Transformers' Apache 2.0 license](licenses/transformers-5.20.1/LICENSE) with those implementations. Transformers source attribution: Copyright 2022 The HuggingFace Inc. team. (image_transforms.py); Copyright 2025 The HuggingFace Inc. team. (image_processing_backends.py).
