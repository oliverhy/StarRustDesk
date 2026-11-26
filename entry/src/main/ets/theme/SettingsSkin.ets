export interface SettingsPalette {
  app: string
  sky: string
  ink: string
  muted: string
  subtle: string
  surface: string
  line: string
  hair: string
  pill: string
  pillEdge: string
  pillHover: string
  pillHighlight: string
  blue: string
  blueSoft: string
  blueHover: string
  blueLine: string
  red: string
  redSoft: string
  redHover: string
  redEdge: string
  green: string
  switchOn: string
  switchOff: string
  thumb: string
}

// The palette inside the approved Settings preview, not the surrounding preview chrome.
const LIGHT: SettingsPalette = {
  app: '#F3F7FD', sky: '#E1EAFB', ink: '#16243A', muted: '#566981', subtle: '#435A78',
  surface: '#FFFFFF', line: '#DCE6F4', hair: '#E6EDF6', pill: '#F0F5FC', pillEdge: '#D9E5F4',
  pillHover: '#E6EEF9', pillHighlight: '#FCFDFE', blue: '#215BB1', blueSoft: '#E4EFFF', blueHover: '#D7E8FD',
  blueLine: '#BACFEC', red: '#A93640', redSoft: '#FCEDEF', redHover: '#FADFE3',
  redEdge: '#F0CCD1', green: '#16705A', switchOn: '#215BB1', switchOff: '#D5DEEA', thumb: '#FFFFFF'
}

const DARK: SettingsPalette = {
  app: '#141D2B', sky: '#19263A', ink: '#F1F5FB', muted: '#B0BFD3', subtle: '#C2D0E4',
  surface: '#1B2638', line: '#31435D', hair: '#29384D', pill: '#242F42', pillEdge: '#3A485D',
  pillHover: '#303E56', pillHighlight: '#2D384A', blue: '#B0D3FF', blueSoft: '#263E60', blueHover: '#304E75',
  blueLine: '#455D7E', red: '#FFB9BD', redSoft: '#432A34', redHover: '#55313C',
  redEdge: '#6F4450', green: '#9CDCCC', switchOn: '#6594D7', switchOff: '#465570', thumb: '#E2EBF8'
}

export function settingsPalette(dark: boolean): SettingsPalette {
  return dark ? DARK : LIGHT
}
