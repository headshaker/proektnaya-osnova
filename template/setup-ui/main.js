'use strict'

const { app, BrowserWindow, ipcMain, net, protocol, session, shell } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const { pathToFileURL } = require('node:url')
const { toPowerShellArguments, validatePayload } = require('./setup-contract')

const scheme = 'project-setup'
const applicationUrl = `${scheme}://app/index.html`
const projectRoot = app.isPackaged
  ? path.resolve(process.resourcesPath, '..', '..', '..')
  : path.resolve(__dirname, '..')
const setupScript = path.join(projectRoot, 'scripts', 'setup-project.ps1')
const toolsScript = path.join(projectRoot, 'scripts', 'configure-project-tools.ps1')
const homePath = path.join(projectRoot, 'HOME.md')
const reportPath = path.join(projectRoot, '.project', 'setup-report.json')
const toolsReportPath = path.join(projectRoot, '.project', 'setup-tools-report.json')
const guideUrls = new Map([
  ['chatgpt', 'https://developers.openai.com/codex/cli'],
  ['claude', 'https://code.claude.com/docs/en/terminal-guide'],
  ['gemini', 'https://google-gemini.github.io/gemini-cli/docs/get-started/deployment.html'],
  ['qwen', 'https://qwenlm.github.io/qwen-code-docs/en/'],
  ['deepseek', 'https://github.com/deepseek-ai/awesome-deepseek-agent/blob/main/docs/deepseek-tui.md'],
  ['grok', 'https://docs.x.ai/build/overview'],
  ['obsidian', 'https://obsidian.md/help/install']
])
const allowedAssets = new Map([
  ['/index.html', path.join(__dirname, 'index.html')],
  ['/styles.css', path.join(__dirname, 'styles.css')],
  ['/renderer.js', path.join(__dirname, 'renderer.js')]
])

let mainWindow = null
let activeRun = null

protocol.registerSchemesAsPrivileged([{
  scheme,
  privileges: {
    standard: true,
    secure: true,
    supportFetchAPI: false,
    corsEnabled: false
  }
}])
app.enableSandbox()

function isTrustedSender (event) {
  return Boolean(event.senderFrame && event.senderFrame.url === applicationUrl)
}

function requireTrustedSender (event) {
  if (!isTrustedSender(event)) throw new Error('Запрос поступил не из окна мастера настройки.')
}

function readSetupReport () {
  if (!fs.existsSync(reportPath)) return null
  try {
    const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'))
    let tools = null
    if (fs.existsSync(toolsReportPath)) {
      try {
        const value = JSON.parse(fs.readFileSync(toolsReportPath, 'utf8'))
        tools = sanitizeToolsResult(value)
      } catch {}
    }
    return {
      result: String(report.result || ''),
      projectTitle: String(report.projectTitle || ''),
      projectSlug: String(report.projectSlug || ''),
      unresolvedDecisions: Array.isArray(report.unresolvedDecisions)
        ? report.unresolvedDecisions.map(value => String(value)).slice(0, 20)
        : [],
      githubProtection: {
        status: String(report.githubProtection?.status || ''),
        message: String(report.githubProtection?.message || '')
      },
      localSync: {
        status: String(report.localSync?.status || ''),
        message: String(report.localSync?.message || '')
      },
      tools,
      nextDocument: String(report.nextDocument || 'HOME.md')
    }
  } catch {
    return null
  }
}

function sanitizeToolsResult (source) {
  const tools = Array.isArray(source?.tools) ? source.tools : []
  return {
    ready: source?.ready === true,
    selectedAiTools: Array.isArray(source?.selectedAiTools)
      ? source.selectedAiTools.map(value => String(value)).slice(0, 6)
      : [],
    tools: tools.map(item => ({
      id: String(item?.id || ''),
      name: String(item?.name || ''),
      selected: item?.selected === true,
      installed: item?.installed === true,
      status: String(item?.status || ''),
      installHint: String(item?.installHint || ''),
      credential: String(item?.credential || ''),
      thirdPartyClient: item?.thirdPartyClient === true
    })).slice(0, 6),
    obsidian: {
      selected: source?.obsidian?.selected === true,
      installed: source?.obsidian?.installed === true,
      status: String(source?.obsidian?.status || ''),
      installHint: String(source?.obsidian?.installHint || '')
    },
    nextSteps: Array.isArray(source?.nextSteps)
      ? source.nextSteps.map(value => String(value)).slice(0, 10)
      : []
  }
}

function runPowerShellArguments (args, timeoutMilliseconds = 10 * 60 * 1000) {
  if (activeRun) return Promise.reject(new Error('Дождитесь завершения текущей проверки.'))

  activeRun = new Promise((resolve, reject) => {
    const child = spawn('pwsh', args, {
      cwd: projectRoot,
      env: {
        ...process.env,
        NO_COLOR: '1',
        TERM: 'dumb',
        POWERSHELL_TELEMETRY_OPTOUT: '1'
      },
      shell: false,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    })

    let stdout = ''
    let stderr = ''
    let overflow = false
    const maximumOutput = 512 * 1024
    const append = (current, chunk) => {
      if (current.length >= maximumOutput) {
        overflow = true
        return current
      }
      return (current + chunk.toString('utf8')).slice(0, maximumOutput)
    }
    child.stdout.on('data', chunk => { stdout = append(stdout, chunk) })
    child.stderr.on('data', chunk => { stderr = append(stderr, chunk) })

    const timeout = setTimeout(() => {
      child.kill()
      reject(new Error('Операция не завершилась вовремя и была остановлена.'))
    }, timeoutMilliseconds)

    child.once('error', error => {
      clearTimeout(timeout)
      reject(error.code === 'ENOENT'
        ? new Error('Не найден PowerShell 7 (pwsh). Установите его и повторите запуск.')
        : error)
    })
    child.once('close', code => {
      clearTimeout(timeout)
      resolve({
        ok: code === 0,
        exitCode: Number.isInteger(code) ? code : 1,
        output: [stdout.trim(), stderr.trim()].filter(Boolean).join('\n'),
        outputTruncated: overflow
      })
    })
  }).finally(() => { activeRun = null })

  return activeRun
}

function runPowerShell (payload, apply) {
  validatePayload(payload)
  const args = toPowerShellArguments(payload, apply)
    .map(value => value === '__SETUP_SCRIPT__' ? setupScript : value)
  return runPowerShellArguments(args).then(result => ({
    ...result,
    report: apply && result.ok ? readSetupReport() : null
  }))
}

function inspectTools (payload) {
  const value = validatePayload(payload)
  const args = [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', toolsScript,
    '-AiToolsCsv', value.aiTools.join(','),
    '-ObsidianMode', value.obsidianEnabled ? 'enabled' : 'disabled',
    '-Date', value.date,
    '-Json'
  ]
  return runPowerShellArguments(args, 60 * 1000).then(result => {
    if (!result.ok) throw new Error(result.output || `Проверка инструментов завершилась с кодом ${result.exitCode}.`)
    try { return sanitizeToolsResult(JSON.parse(result.output)) }
    catch { throw new Error('Проверка инструментов вернула непонятный результат.') }
  })
}

function configureIpc () {
  ipcMain.handle('setup:get-defaults', event => {
    requireTrustedSender(event)
    const readme = fs.readFileSync(path.join(projectRoot, 'README.md'), 'utf8')
    const projectTitleToken = '{{' + 'PROJECT_TITLE' + '}}'
    const today = new Date().toISOString().slice(0, 10)
    return {
      canConfigure: readme.includes(projectTitleToken),
      date: today,
      electronVersion: process.versions.electron
    }
  })
  ipcMain.handle('setup:preview', (event, payload) => {
    requireTrustedSender(event)
    return runPowerShell(payload, false)
  })
  ipcMain.handle('setup:inspect-tools', (event, payload) => {
    requireTrustedSender(event)
    return inspectTools(payload)
  })
  ipcMain.handle('setup:apply', (event, payload) => {
    requireTrustedSender(event)
    return runPowerShell(payload, true)
  })
  ipcMain.handle('setup:open-home', async event => {
    requireTrustedSender(event)
    if (!fs.existsSync(homePath)) throw new Error('Не найден HOME.md.')
    const error = await shell.openPath(homePath)
    if (error) throw new Error(error)
    return true
  })
  ipcMain.handle('setup:open-guide', async (event, guideId) => {
    requireTrustedSender(event)
    const url = guideUrls.get(String(guideId || ''))
    if (!url) throw new Error('Неизвестная инструкция по установке.')
    await shell.openExternal(url)
    return true
  })
  ipcMain.handle('setup:open-obsidian', async event => {
    requireTrustedSender(event)
    if (!fs.existsSync(path.join(projectRoot, '.obsidian'))) {
      throw new Error('Obsidian не был выбран при настройке проекта.')
    }
    await shell.openExternal(`obsidian://open?path=${encodeURIComponent(projectRoot)}`)
    return true
  })
}

async function configureProtocol () {
  await protocol.handle(scheme, request => {
    const url = new URL(request.url)
    const asset = url.host === 'app' ? allowedAssets.get(url.pathname) : null
    if (!asset) return new Response('Not found', { status: 404 })
    return net.fetch(pathToFileURL(asset).toString())
  })
}

function createWindow () {
  mainWindow = new BrowserWindow({
    width: 1120,
    height: 780,
    minWidth: 900,
    minHeight: 680,
    show: false,
    title: 'Настройка проекта',
    backgroundColor: '#f4f1ea',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      devTools: false
    }
  })
  mainWindow.removeMenu()
  mainWindow.webContents.on('will-navigate', event => event.preventDefault())
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  mainWindow.once('ready-to-show', () => mainWindow.show())
  mainWindow.on('closed', () => { mainWindow = null })
  mainWindow.loadURL(applicationUrl)
}

const singleInstance = app.requestSingleInstanceLock()
if (!singleInstance) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (!mainWindow) return
    if (mainWindow.isMinimized()) mainWindow.restore()
    mainWindow.focus()
  })
  app.whenReady().then(async () => {
    session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false))
    await configureProtocol()
    configureIpc()
    createWindow()
  })
  app.on('window-all-closed', () => app.quit())
}
