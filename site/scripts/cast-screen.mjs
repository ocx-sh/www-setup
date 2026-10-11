// The text a reader sees at the end of a cast: output events replayed onto a line buffer that understands
// carriage return, line feed and the cursor-up, cursor-down and erase-line sequences a progress bar redraws with.
// Lines wrap at the cast's width, since the redraw counts wrapped rows, and are joined again at the end. Colour and every other control sequence are dropped. The page sessions are checked against it (session-casts.test.mjs).

/** The cast's final screen as trimmed lines, with the typed prompt line first. */
export function screenLines(castText) {
  const [head, ...events] = castText.trim().split('\n');
  const cols = JSON.parse(head).term.cols;
  const lines = [''];
  const wrapped = new Set(); // rows that continue the row above
  let row = 0;
  let col = 0;
  const put = (ch) => {
    if (col >= cols) { move(row + 1); wrapped.add(row); col = 0; }
    const l = lines[row].padEnd(col);
    lines[row] = l.slice(0, col) + ch + l.slice(col + 1);
    col++;
  };
  const move = (to) => {
    row = Math.max(0, to);
    while (lines.length <= row) lines.push('');
  };
  for (const e of events) {
    const [, code, data] = JSON.parse(e);
    if (code !== 'o') continue;
    for (let i = 0; i < data.length; i++) {
      const ch = data[i];
      if (ch === '\x1b' && data[i + 1] === '[') {
        const m = /^[0-9;?]*([A-Za-z])/.exec(data.slice(i + 2));
        if (!m) continue;
        const n = Number.parseInt(m[0], 10) || 1;
        if (m[1] === 'A') move(row - n);
        else if (m[1] === 'B') move(row + n);
        else if (m[1] === 'K') {
          lines[row] = m[0].startsWith('2') ? '' : lines[row].slice(0, col);
          if (m[0].startsWith('2')) wrapped.delete(row);
        }
        i += 1 + m[0].length;
      } else if (ch === '\x1b' && data[i + 1] === '(') i += 2; // charset select, ESC ( B
      else if (ch === '\x1b' && '=>'.includes(data[i + 1])) i += 1; // keypad mode
      else if (ch === '\x1b' && data[i + 1] === ']') { // OSC, up to BEL or ST
        const end = data.slice(i).search(/\x07|\x1b\\/);
        i = end < 0 ? data.length : i + end + (data[i + end] === '\x07' ? 0 : 1);
      } else if (ch === '\r') col = 0;
      else if (ch === '\n') { move(row + 1); wrapped.delete(row); col = 0; }
      else put(ch);
    }
  }
  const out = [];
  for (const [i, l] of lines.entries()) {
    if (wrapped.has(i)) out[out.length - 1] += l;
    else out.push(l);
  }
  for (const [i, l] of out.entries()) out[i] = l.trimEnd();
  while (out.length && !out.at(-1)) out.pop();
  return out;
}
