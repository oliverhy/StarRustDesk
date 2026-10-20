// Inputs are single-line, so grow the field rather than shrinking text or wrapping typed data.
export function readableInputHeight(minimum: number, fontScale: number, fontSize: number = 16): number {
  const scale = Number.isFinite(fontScale) ? Math.max(1, fontScale) : 1
  const size = Number.isFinite(fontSize) ? Math.max(1, fontSize) : 16
  return Math.max(minimum, Math.ceil(size * scale * 1.5 + 16))
}

export function readableLabelHeight(text: string, width: number, fontScale: number,
  fontSize: number = 14, minimum: number = 44): number {
  const scale = Number.isFinite(fontScale) ? Math.max(1, fontScale) : 1
  const available = Number.isFinite(width) ? Math.max(1, width) : 120
  let units: number = 0
  for (let index = 0; index < text.length; index++) units += text.charCodeAt(index) <= 127 ? 0.65 : 1
  const lines = Math.max(1, Math.ceil(units * fontSize * scale / available))
  return Math.max(minimum, Math.ceil(lines * fontSize * scale * 1.5 + 16))
}
