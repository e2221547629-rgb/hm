import { SpeechKitService } from '../services/SpeechKitService'

class CalculatorEngine {
  static normalizeVoice(text: string): string {
    let value: string = text.trim()
    const replacements: Array<Array<string>> = [
      ['乘以', '*'], ['乘上', '*'], ['乘', '*'], ['×', '*'],
      ['除以', '/'], ['除', '/'], ['÷', '/'],
      ['加上', '+'], ['加', '+'], ['＋', '+'],
      ['减去', '-'], ['减', '-'], ['−', '-'], ['－', '-'],
      ['等于', '='], ['结果是', '='], ['小数点', '.'], ['点', '.']
    ]
    replacements.forEach((pair: Array<string>) => value = value.split(pair[0]).join(pair[1]))
    value = CalculatorEngine.chineseNumberToArabic(value)
    value = value.replace(/[^0-9+\-*/().%=]/g, '').replace(/%/g, '/100')
    return value.replace(/=/g, '')
  }

  static chineseNumberToArabic(text: string): string {
    const digitMap: Record<string, string> = {
      '零': '0', '〇': '0', '一': '1', '二': '2', '两': '2', '三': '3',
      '四': '4', '五': '5', '六': '6', '七': '7', '八': '8', '九': '9'
    }
    let result: string = ''
    let pending: string = ''
    const flushNumber = (): void => {
      if (pending.length === 0) return
      let total: number = 0
      let section: number = 0
      let number: number = 0
      for (let j: number = 0; j < pending.length; j++) {
        const digit: string = pending.charAt(j)
        if (digitMap[digit] !== undefined) {
          number = Number(digitMap[digit])
        } else if (digit === '十' || digit === '百' || digit === '千') {
          const unit: number = digit === '十' ? 10 : (digit === '百' ? 100 : 1000)
          section += (number === 0 ? 1 : number) * unit
          number = 0
        }
      }
      total = section + number
      result += String(total)
      pending = ''
    }
    for (let i: number = 0; i < text.length; i++) {
      const char: string = text.charAt(i)
      if (digitMap[char] !== undefined) {
        pending += digitMap[char]
        continue
      }
      if (char === '十' || char === '百' || char === '千') {
        pending += char
        continue
      }
      flushNumber()
      result += char
    }
    flushNumber()
    return result
  }

  static evaluate(expression: string): number {
    const clean: string = expression.replace(/\s/g, '')
    const tokens: Array<string> = clean.match(/(\d+(?:\.\d+)?|[+\-*/()])/g) || []
    if (tokens.length === 0 || tokens.join('') !== clean) throw new Error('算式格式不正确')
    const values: Array<number> = []
    const operators: Array<string> = []
    const precedence: Record<string, number> = { '+': 1, '-': 1, '*': 2, '/': 2 }
    const applyTop = (): void => {
      const op: string | undefined = operators.pop()
      const right: number | undefined = values.pop()
      const left: number | undefined = values.pop()
      if (op === undefined || right === undefined || left === undefined) throw new Error('算式不完整')
      if (op === '/' && right === 0) throw new Error('除数不能为零')
      values.push(op === '+' ? left + right : op === '-' ? left - right : op === '*' ? left * right : left / right)
    }
    tokens.forEach((token: string, index: number) => {
      if (/^\d/.test(token)) values.push(Number(token))
      else if (token === '(') operators.push(token)
      else if (token === ')') {
        while (operators.length > 0 && operators[operators.length - 1] !== '(') applyTop()
        if (operators.pop() !== '(') throw new Error('括号不匹配')
      } else {
        const unaryMinus: boolean = token === '-' && (index === 0 || ['+', '-', '*', '/'].includes(tokens[index - 1]))
        if (index === 0 || ['+', '-', '*', '/'].includes(tokens[index - 1])) {
          if (unaryMinus) values.push(0)
          else throw new Error('运算符位置不正确')
        }
        while (!unaryMinus && operators.length > 0 && operators[operators.length - 1] !== '(' && precedence[operators[operators.length - 1]] >= precedence[token]) applyTop()
        operators.push(token)
      }
    })
    while (operators.length > 0) {
      if (operators[operators.length - 1] === '(') throw new Error('括号不匹配')
      applyTop()
    }
    if (values.length !== 1 || !Number.isFinite(values[0])) throw new Error('无法计算该算式')
    return values[0]
  }

  static format(value: number): string {
    return Number(value.toFixed(10)).toString()
  }
}

@Entry
@Component
struct Index {
  @State expression: string = ''
  @State result: string = '0'
  @State recognizedText: string = '请输入算式'
  @State speechEnabled: boolean = true

  aboutToAppear(): void {
    SpeechKitService.prepare().catch(() => {
      this.speechEnabled = false
      this.recognizedText = '按键播报暂不可用，可继续计算'
    })
  }

  aboutToDisappear(): void {
    SpeechKitService.release()
  }

  private append(value: string): void {
    let speech: string = this.keySpeech(value)
    let priority: boolean = false
    if (value === 'AC') {
      this.expression = ''
      this.result = '0'
      this.recognizedText = '请输入算式'
      speech = '全部清除'
      priority = true
    } else if (value === '⌫') {
      this.expression = this.expression.slice(0, -1)
      speech = '删除'
      priority = true
    } else if (value === '=') {
      const expressionToRead: string = this.expression
      this.calculate()
      speech = this.recognizedText === '计算完成' ?
        `${this.expressionSpeech(expressionToRead)}，等于 ${this.result}` : this.recognizedText
      priority = true
    } else if (value === '%') {
      this.expression += '%'
      this.calculate()
    } else {
      this.expression += value
    }
    this.playFeedback(speech, priority)
  }

  private calculate(): void {
    if (this.expression.length === 0) return
    try {
      const normalized: string = CalculatorEngine.normalizeVoice(this.expression)
      this.result = CalculatorEngine.format(CalculatorEngine.evaluate(normalized))
      this.recognizedText = '计算完成'
    } catch (error) {
      this.recognizedText = (error as Error).message
    }
  }

  private keySpeech(value: string): string {
    const speechNames: Record<string, string> = {
      '0': '零', '1': '一', '2': '二', '3': '三', '4': '四',
      '5': '五', '6': '六', '7': '七', '8': '八', '9': '九',
      '*': '乘', '/': '除', '+': '加', '-': '减', '.': '点',
      '%': '百分号', '(': '左括号', ')': '右括号', '=': '等于',
      'AC': '全部清除', '⌫': '删除'
    }
    return speechNames[value] !== undefined ? speechNames[value] : value
  }

  private expressionSpeech(expression: string): string {
    let speech: string = ''
    for (let i: number = 0; i < expression.length; i++) {
      speech += `${this.keySpeech(expression.charAt(i))}，`
    }
    return speech.endsWith('，') ? speech.slice(0, -1) : speech
  }

  private playFeedback(text: string, priority: boolean): void {
    if (!this.speechEnabled || text.length === 0) return
    const task: Promise<void> = priority ?
      SpeechKitService.speakPriority(text) : SpeechKitService.speakKey(text)
    task.catch((error: Error) => {
      if (error.message === '播报已取消') return
      this.speechEnabled = false
      this.recognizedText = '按键播报暂不可用，点击“播报 关”重试'
    })
  }

  private async toggleSpeech(): Promise<void> {
    if (this.speechEnabled) {
      this.speechEnabled = false
      SpeechKitService.stopSpeaking()
      this.recognizedText = '按键播报已关闭'
      return
    }
    this.recognizedText = '正在开启按键播报…'
    try {
      await SpeechKitService.prepare()
      this.speechEnabled = true
      this.recognizedText = '按键播报已开启'
      this.playFeedback('按键播报已开启', true)
    } catch (_) {
      this.speechEnabled = false
      this.recognizedText = '按键播报暂不可用，可继续计算'
    }
  }

  build() {
    Column({ space: 8 }) {
      Text('智能语音计算器')
        .fontSize(28).fontWeight(FontWeight.Bold).fontColor('#25212B').margin({ top: 10 })
      Column({ space: 8 }) {
        Text(this.expression.length > 0 ? this.expression : '输入算式')
          .fontSize(22).fontColor('#696370').maxLines(1).textAlign(TextAlign.End).width('100%')
        Text(this.result)
          .fontSize(42).fontWeight(FontWeight.Bold).fontColor('#1D1824').maxLines(1).textAlign(TextAlign.End).width('100%')
        Text(this.recognizedText)
          .fontSize(13).fontColor('#746C7C').maxLines(2).textAlign(TextAlign.End).width('100%')
      }
      .padding(16).width('92%').height(150).backgroundColor('#EAE7EC').borderRadius(25)
      Row() {
        Blank()
        Button(this.speechEnabled ? '按键播报  开' : '按键播报  关')
          .fontSize(14)
          .fontColor('#332B3D')
          .backgroundColor(this.speechEnabled ? '#E4D5F8' : '#EEEAF1')
          .borderRadius(16)
          .width(118)
          .height(36)
          .onClick(() => this.toggleSpeech())
      }
      .width('92%')
      GridRow({ columns: 4, gutter: 8 }) {
        ForEach(['AC', '⌫', '%', '/'], (key: string) => {
          GridCol() { this.keyButton(key, '#EEEAF1') }
        })
        ForEach(['7', '8', '9', '*', '4', '5', '6', '-', '1', '2', '3', '+', '0', '.', '(', ')'], (key: string) => {
          GridCol() { this.keyButton(key, ['*', '-', '+', '/'].includes(key) ? '#E4D5F8' : '#F7F3FA') }
        })
        GridCol() { this.keyButton('=', '#B998D8') }
      }
      .width('92%').layoutWeight(1)
    }
    .width('100%').height('100%').padding({ left: 12, right: 12, bottom: 8 }).backgroundColor('#FBF8FC')
  }

  @Builder
  keyButton(key: string, color: string) {
    Button(key).fontSize(key === '=' ? 27 : 20).fontWeight(FontWeight.Medium).fontColor('#302837')
      .backgroundColor(color).borderRadius(17).height(48).width('100%')
      .onClick(() => this.append(key))
  }
}
