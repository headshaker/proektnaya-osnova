'use strict'

const { app, BrowserWindow, ipcMain, net, protocol, session, shell } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const { StringDecoder } = require('node:string_decoder')
const { pathToFileURL } = require('node:url')
const { toPowerShellArguments, validatePayload } = require('./setup-contract')

const scheme = 'project-setup'
const applicationUrl = `${scheme}://app/index.html`
const projectRoot = app.isPackaged
  ? path.resolve(process.resourcesPath, '..', '..', '..')
  : path.resolve(__dirname, '..')
const setupScript = path.join(projectRoot, 'scripts', 'setup-project.ps1')
const toolsScript = path.join(projectRoot, 'scripts', 'configure-project-tools.ps1')
const localSyncInstaller = path.join(projectRoot, 'scripts', 'install-local-sync.ps1')
const homePath = path.join(projectRoot, 'HOME.md')
const reportPath = path.join(projectRoot, '.project', 'setup-report.json')
const toolsReportPath = path.join(projectRoot, '.project', 'setup-tools-report.json')
const localSyncReportPath = path.join(projectRoot, '.project', 'local-sync-installation.json')
const localSyncLogPath = path.join(projectRoot, '.project', 'local-sync.log')
const localSyncDisablePath = path.join(projectRoot, '.project', 'local-sync.disabled')
const bundledPowerShell = app.isPackaged
  ? path.resolve(process.resourcesPath, '..', 'powershell', 'pwsh.exe')
  : ''
const hasBundledPowerShell = Boolean(bundledPowerShell && fs.existsSync(bundledPowerShell))
const powerShellExecutable = hasBundledPowerShell ? bundledPowerShell : 'pwsh'
const guideUrls = new Map([
  ['chatgpt', 'https://developers.openai.com/codex/cli'],
  ['claude', 'https://code.claude.com/docs/en/terminal-guide'],
  ['gemini', 'https://google-gemini.github.io/gemini-cli/docs/get-started/deployment.html'],
  ['qwen', 'https://qwenlm.github.io/qwen-code-docs/en/'],
  ['deepseek', 'https://github.com/deepseek-ai/awesome-deepseek-agent/blob/main/docs/deepseek-tui.md'],
  ['grok', 'https://docs.x.ai/build/overview'],
  ['obsidian', 'https://obsidian.md/help/install']
])
const projectGuidePaths = new Map([
  ['start-here', path.join(projectRoot, 'START-HERE.md')],
  ['prompting', path.join(projectRoot, 'PROMPTING-GUIDE.md')],
  ['team-input', path.join(projectRoot, 'TEAM-INPUT.md')]
])
const allowedAssets = new Map([
  ['/index.html', path.join(__dirname, 'index.html')],
  ['/styles.css', path.join(__dirname, 'styles.css')],
  ['/renderer.js', path.join(__dirname, 'renderer.js')]
])

let mainWindow = null
let activeRun = null

function readLocalSyncState () {
  let policyEnabled = true
  try {
    const configuration = JSON.parse(fs.readFileSync(path.join(projectRoot, 'LOCAL-SYNC.json'), 'utf8'))
    policyEnabled = configuration.enabled === true
  } catch {}

  let report = null
  try { report = JSON.parse(fs.readFileSync(localSyncReportPath, 'utf8')) } catch {}
  const localEnabled = !fs.existsSync(localSyncDisablePath)
  const enabled = policyEnabled && localEnabled
  return {
    enabled,
    policyEnabled,
    localEnabled,
    status: String(report?.status || (enabled ? 'not-installed' : (policyEnabled ? 'disabled-local' : 'disabled-policy'))),
    message: String(report?.message || (enabled
      ? 'Фоновое обновление ещё не настроено на этом компьютере.'
      : (policyEnabled ? 'Фоновое обновление отключено на этом компьютере.' : 'Автоматическое обновление отключено политикой проекта.'))),
    logAvailable: fs.existsSync(localSyncLogPath),
    logPath: localSyncLogPath
  }
}

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
    const child = spawn(powerShellExecutable, args, {
      cwd: projectRoot,
      env: {
        ...process.env,
        NO_COLOR: '1',
        TERM: 'dumb',
        POWERSHELL_TELEMETRY_OPTOUT: '1',
        PROJECT_SETUP_STDIO_ENCODING: 'utf8'
      },
      shell: false,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    })

    let stdout = ''
    let stderr = ''
    let overflow = false
    const maximumOutput = 512 * 1024
    const stdoutDecoder = new StringDecoder('utf8')
    const stderrDecoder = new StringDecoder('utf8')
    const append = (current, text) => {
      if (current.length >= maximumOutput) {
        if (text.length > 0) overflow = true
        return current
      }
      const combined = current + text
      if (combined.length > maximumOutput) overflow = true
      return combined.slice(0, maximumOutput)
    }
    child.stdout.on('data', chunk => { stdout = append(stdout, stdoutDecoder.write(chunk)) })
    child.stderr.on('data', chunk => { stderr = append(stderr, stderrDecoder.write(chunk)) })

    const timeout = setTimeout(() => {
      child.kill()
      reject(new Error('Операция не завершилась вовремя и была остановлена.'))
    }, timeoutMilliseconds)

    child.once('error', error => {
      clearTimeout(timeout)
      reject(error.code === 'ENOENT'
        ? new Error(app.isPackaged
            ? 'В выпуске отсутствует внутренний механизм настройки. Скачайте официальный архив повторно или передайте ADMIN-SETUP.md техническому специалисту.'
            : 'Исходная копия не подготовлена для обычного запуска. Техническому специалисту нужен PowerShell 7; подробности находятся в ADMIN-SETUP.md.')
        : error)
    })
    child.once('close', code => {
      clearTimeout(timeout)
      stdout = append(stdout, stdoutDecoder.end())
      stderr = append(stderr, stderrDecoder.end())
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

function configureLocalSync (enabled) {
  if (!fs.existsSync(localSyncInstaller)) {
    return Promise.reject(new Error('Не найден внутренний механизм управления обновлением.'))
  }
  const args = [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', localSyncInstaller,
    '-ProjectPath', projectRoot, '-Apply', enabled ? '-Enable' : '-Disable', '-Json'
  ]
  return runPowerShellArguments(args, 60 * 1000).then(result => {
    if (!result.ok) throw new Error(result.output || 'Не удалось изменить настройку фонового обновления.')
    try { JSON.parse(result.output) } catch { throw new Error('Механизм обновления вернул непонятный результат.') }
    return readLocalSyncState()
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
      electronVersion: process.versions.electron,
      automationReady: hasBundledPowerShell || !app.isPackaged,
      runtimeLabel: hasBundledPowerShell ? 'Автономный запуск' : 'Режим разработки',
      localSync: readLocalSyncState()
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
  ipcMain.handle('setup:set-local-sync', (event, enabled) => {
    requireTrustedSender(event)
    if (typeof enabled !== 'boolean') throw new Error('Неизвестное состояние фонового обновления.')
    return configureLocalSync(enabled)
  })
  ipcMain.handle('setup:open-local-sync-log', async event => {
    requireTrustedSender(event)
    if (!fs.existsSync(localSyncLogPath)) throw new Error('Журнал ещё не создан. Выполните первую проверку обновлений.')
    const error = await shell.openPath(localSyncLogPath)
    if (error) throw new Error(error)
    return true
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
  ipcMain.handle('setup:open-project-guide', async (event, guideId) => {
    requireTrustedSender(event)
    const guidePath = projectGuidePaths.get(String(guideId || ''))
    if (!guidePath || !fs.existsSync(guidePath)) throw new Error('Не найдено выбранное руководство проекта.')
    const error = await shell.openPath(guidePath)
    if (error) throw new Error(error)
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
