# 会声 · HuiSheng v0.5.0

2026-11-05 · 预览版 / Preview

## 简体中文

录音结束并保存后，会声现在可以在本机生成会议名称与总结。关闭实时转录时，先用所选引擎补转录，再生成总结；选择 Whisper 多语言模型即可自动识别语音语言。

### 本次新增

- Apple 本地大语言模型生成标题、讨论要点、已确认决定、待办事项和待确认问题。
- 自动为未命名录音起名，保留手动名称以及原音频文件路径。
- 自动识别中文和英文会议的总结语言；其他语言回退到界面语言。
- 总结与转录并排显示，继续支持圈选追问；Markdown 导出包含总结、原文和追问。
- 后台排队、停止与重试。录音先保存；取消或生成失败时保留录音、转录和旧总结。
- 长转录分段汇总；转录变化后提示旧总结可能过时。

软件支持中文、英文即时切换。Whisper 实时/事后转录、自动语言识别、API/本机模型/本地 Agent 追问等已有功能继续保留。

### 开始使用

选择「Whisper → 自动识别」，开启「结束后自动命名与总结」。需要边录边看文字时开启「实时转录」；两个开关都关闭时只录音。已有录音可以直接点击「总结」。

录音和 Whisper 支持 macOS 15+；自动总结需要 macOS 26、兼容的 Apple Silicon Mac，以及已就绪的 Apple Intelligence 本地模型。Whisper 程序和多语言模型需要另外安装。自动总结在本机完成，不使用追问 API 或 Agent；追问后端可能连接云端。

升级前先结束并保存录音，再替换应用。临时签名更新可能需要重新授予系统音频和麦克风权限，具体步骤见 [中文 README](https://github.com/chenxiachan/HuiSheng/blob/main/README.zh-CN.md)。

### 验证范围

已用合成语音验证真实本地 Whisper 自动转录、Apple 模型中英文总结、标题与总结保存及原音频保持不变；已检查中英文原生界面、圈选追问、Markdown 导出，并通过音频、后台队列、取消、文件保护和问答回归检查。

预览版使用临时签名，尚未经过 Apple 公证。摘要可能遗漏或误归类，重要信息请核对原文和录音。各会议客户端的真实通话、长会议总结质量仍需更广泛测试。

[中文产品介绍](https://github.com/chenxiachan/HuiSheng/blob/main/docs/PRODUCT.zh-CN.md)

## English

After recording is saved, HuiSheng can now generate a meeting title and summary on your Mac. With live transcription off, it first transcribes the audio using your selected engine. A multilingual Whisper model can detect the spoken language automatically.

### What's new

- Apple's on-device language model generates a title, discussion points, confirmed decisions, action items, and open questions.
- Untitled recordings receive automatic names; user-entered names and audio paths are preserved.
- Summary language follows detected Chinese or English meeting text; other languages fall back to the interface language.
- Summaries appear beside the transcript, with selection-based Q&A available. Markdown export includes the summary, transcript, and discussions.
- Background queues, cancellation, and retry. Audio is saved first; cancellation or generation failure preserves recordings, text, and previous summaries.
- Long transcripts are summarized in sections. Changed transcripts mark older summaries as potentially out of date.

The app supports instant Chinese/English interface switching. Existing Whisper live/file transcription, automatic speech-language detection, and Q&A through APIs, local models, or installed agents remain available.

### Get started

Choose **Whisper → Detect automatically** and enable **Auto title & summary after recording**. Enable **Live transcription** to see text during the meeting; turn both switches off for audio only. Existing recordings have a **Summary** button.

Recording and Whisper support macOS 15+. Automatic summaries require macOS 26, a compatible Apple Silicon Mac, and a ready Apple Intelligence on-device model. Install the Whisper executable and multilingual model separately. Automatic summaries run locally and do not use your Q&A API or agent; Q&A backends may connect to cloud services.

Stop and save recordings before updating the app. An updated ad-hoc signature may require renewed system-audio and microphone permissions; see the [English README](https://github.com/chenxiachan/HuiSheng/blob/main/README.md) for recovery steps.

### Validation

Synthetic speech was used to verify actual local Whisper transcription, Chinese/English Apple model summaries, saved titles and summaries, and unchanged audio. Native bilingual UI, selection-based Q&A, and Markdown export were checked. Audio, background queue, cancellation, file protection, and Q&A regression checks passed.

This preview is ad-hoc signed and not notarized by Apple. Summaries may omit or misclassify information; check important details against the transcript and recording. Real calls across individual meeting clients and long-meeting summary quality need broader testing.

[English product introduction](https://github.com/chenxiachan/HuiSheng/blob/main/docs/PRODUCT.md)
