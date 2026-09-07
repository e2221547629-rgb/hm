import { textToSpeech, speechRecognizer } from '@kit.CoreSpeechKit'

interface SpeechTask {
  text: string
  requestId: string
  resolve: () => void
  reject: (error: Error) => void
}

/**
 * Core Speech Kit 的最小封装。
 * TTS 用于结果播报，ASR 使用 Core Speech Kit 的实时录音识别模式。
 */
export class SpeechKitService {
  private static engine: textToSpeech.TextToSpeechEngine | undefined = undefined
  private static speechQueue: Array<SpeechTask> = []
  private static currentTask: SpeechTask | undefined = undefined
  private static requestSequence: number = 0
  private static playbackTimeout: number = -1
  private static asrEngine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined
  private static sessionId: string = ''

  private static enginePromise: Promise<textToSpeech.TextToSpeechEngine> | undefined = undefined
  private static engineGeneration: number = 0

  private static async ensureTtsEngine(): Promise<textToSpeech.TextToSpeechEngine> {
    if (SpeechKitService.engine !== undefined) return SpeechKitService.engine
    if (SpeechKitService.enginePromise === undefined) {
      SpeechKitService.enginePromise = SpeechKitService.createTtsEngine()
    }
    const pending = SpeechKitService.enginePromise
    try {
      return await pending
    } finally {
      if (SpeechKitService.enginePromise === pending) SpeechKitService.enginePromise = undefined
    }
  }

  private static async createTtsEngine(): Promise<textToSpeech.TextToSpeechEngine> {
    const generation: number = SpeechKitService.engineGeneration
    const engine = await textToSpeech.createEngine({
      language: 'zh-CN',
      person: 0,
      online: 1,
      extraParams: { 'style': 'interaction-broadcast', 'locate': 'CN' }
    })
    if (generation !== SpeechKitService.engineGeneration) {
      engine.shutdown()
      throw new Error('播报已取消')
    }
    engine.setListener({
      onStart: () => undefined,
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
        // 合成完成并不代表播放完成。
        if (response.type === 1) SpeechKitService.finishTask(requestId)
      },
      onStop: (requestId: string) => {
        SpeechKitService.finishTask(requestId, new Error('播报已取消'))
      },
      onError: (requestId: string, errorCode: number, errorMessage: string) => {
        if (SpeechKitService.engine !== engine ||
          SpeechKitService.currentTask?.requestId !== requestId) return
        SpeechKitService.resetTtsEngine()
        SpeechKitService.finishTask(requestId, new Error(`${errorMessage} (${errorCode})`))
      }
    })
    SpeechKitService.engine = engine
    return engine
  }

  private static finishTask(requestId: string, error?: Error): void {
    const task = SpeechKitService.currentTask
    if (task === undefined || task.requestId !== requestId) return
    SpeechKitService.clearPlaybackTimeout()
    SpeechKitService.currentTask = undefined
    if (error !== undefined) task.reject(error)
    else task.resolve()
    SpeechKitService.playNext()
  }

  private static resetTtsEngine(): void {
    const engine = SpeechKitService.engine
    SpeechKitService.engine = undefined
    SpeechKitService.enginePromise = undefined
    SpeechKitService.engineGeneration++
    try { engine?.shutdown() } catch (_) { }
  }

  static async prepare(): Promise<void> {
    await SpeechKitService.ensureTtsEngine()
  }

  static async speakKey(text: string): Promise<void> {
    await SpeechKitService.enqueue(text, 'key')
  }

  static async speak(text: string): Promise<void> {
    await SpeechKitService.enqueue(text, 'calculator')
  }

  static async speakPriority(text: string): Promise<void> {
    SpeechKitService.stopSpeaking()
    await SpeechKitService.enqueue(text, 'priority')
  }

  private static enqueue(text: string, prefix: string): Promise<void> {
    if (text.length === 0) return Promise.resolve()
    SpeechKitService.requestSequence++
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      SpeechKitService.speechQueue.push({
        text: text,
        requestId: `${prefix}${Date.now()}${SpeechKitService.requestSequence}`,
        resolve: resolve,
        reject: reject
      })
      SpeechKitService.playNext()
    })
  }

  private static async playNext(): Promise<void> {
    if (SpeechKitService.currentTask !== undefined || SpeechKitService.speechQueue.length === 0) return
    const task: SpeechTask | undefined = SpeechKitService.speechQueue.shift()
    if (task === undefined) return
    SpeechKitService.currentTask = task
    try {
      const engine: textToSpeech.TextToSpeechEngine = await SpeechKitService.ensureTtsEngine()
      if (SpeechKitService.currentTask !== task) return
      engine.speak(task.text, {
        requestId: task.requestId,
        extraParams: {
          'queueMode': 0,
          'speed': 0.9,
          'volume': 2,
          'pitch': 1,
          'languageContext': 'zh-CN',
          'audioType': 'pcm',
          'soundChannel': 3,
          'playType': 1
        }
      })
      if (SpeechKitService.currentTask !== task) return
      const timeoutMs: number = Math.max(15000, 5000 + task.text.length * 600)
      SpeechKitService.playbackTimeout = setTimeout(() => {
        if (SpeechKitService.currentTask?.requestId !== task.requestId) return
        SpeechKitService.resetTtsEngine()
        SpeechKitService.finishTask(task.requestId, new Error('语音播报超时，请重试'))
      }, timeoutMs)
    } catch (error) {
      if (SpeechKitService.currentTask !== task) return
      SpeechKitService.resetTtsEngine()
      SpeechKitService.finishTask(task.requestId, error as Error)
    }
  }

  private static clearPlaybackTimeout(): void {
    if (SpeechKitService.playbackTimeout >= 0) {
      clearTimeout(SpeechKitService.playbackTimeout)
      SpeechKitService.playbackTimeout = -1
    }
  }

  static stopSpeaking(): void {
    SpeechKitService.clearPlaybackTimeout()
    const task = SpeechKitService.currentTask
    SpeechKitService.currentTask = undefined
    const cancelled = new Error('播报已取消')
    SpeechKitService.speechQueue.forEach((queued: SpeechTask) => queued.reject(cancelled))
    SpeechKitService.speechQueue = []
    task?.reject(cancelled)
    // 先清理任务，再停止引擎；迟到的完成/停止回调不能推进新队列。
    try { SpeechKitService.engine?.stop() } catch (_) { }
  }

  static async release(): Promise<void> {
    SpeechKitService.stopSpeaking()
    SpeechKitService.resetTtsEngine()
    await SpeechKitService.stopRecognition()
  }

  static async startRecognition(onText: (text: string, isFinal: boolean) => void, onError: (message: string) => void): Promise<void> {
    if (SpeechKitService.asrEngine !== undefined) {
      onError('语音识别正在进行')
      return
    }
    try {
      SpeechKitService.stopSpeaking()
      SpeechKitService.asrEngine = await speechRecognizer.createEngine({
        language: 'zh-CN',
        online: 1,
        extraParams: { 'locate': 'CN', 'recognizerMode': 'short' }
      })
      SpeechKitService.sessionId = `calculator-${Date.now()}`
      SpeechKitService.asrEngine.setListener({
        onStart: () => undefined,
        onEvent: () => undefined,
        onResult: (_sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
          if (result.result.length === 0) return
          if (result.isFinal) {
            const finalText: string = result.result
            SpeechKitService.stopRecognition(false).then(() => onText(finalText, true))
          } else {
            onText(result.result, false)
          }
        },
        onComplete: () => undefined,
        onError: (_sessionId: string, _errorCode: number, errorMessage: string) => {
          SpeechKitService.stopRecognition(false)
          onError(errorMessage)
        }
      })
      SpeechKitService.asrEngine.startListening({
        sessionId: SpeechKitService.sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
        extraParams: { 'recognitionMode': 0, 'vadBegin': 1000, 'vadEnd': 800 }
      })
    } catch (error) {
      await SpeechKitService.stopRecognition()
      onError((error as Error).message)
    }
  }

  static finishRecognition(): void {
    if (SpeechKitService.asrEngine !== undefined && SpeechKitService.sessionId.length > 0) {
      try { SpeechKitService.asrEngine.finish(SpeechKitService.sessionId) } catch (_) { }
    }
  }

  static async stopRecognition(sendFinish: boolean = true): Promise<void> {
    if (sendFinish) SpeechKitService.finishRecognition()
    if (SpeechKitService.asrEngine !== undefined) {
      try { SpeechKitService.asrEngine.shutdown() } catch (_) { }
    }
    SpeechKitService.asrEngine = undefined
    SpeechKitService.sessionId = ''
  }
}
