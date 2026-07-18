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
const homePath = path.join(projectRoot, 'HOME.md')
const reportPath = path.join(projectRoot, '.project', 'setup-report.json')
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
      nextDocument: String(report.nextDocument || 'HOME.md')
    }
  } catch {
    return null
  }
}

function runPowerShell (payload, apply) {
  validatePayload(payload)
  if (activeRun) return Promise.reject(new Error('Дождитесь завершения текущей проверки.'))

  activeRun = new Promise((resolve, reject) => {
    const args = toPowerShellArguments(payload, apply)
      .map(value => value === '__SETUP_SCRIPT__' ? setupScript : value)
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
      reject(new Error('Настройка не завершилась за 10 минут и была остановлена.'))
    }, 10 * 60 * 1000)

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
        outputTruncated: overflow,
        report: apply && code === 0 ? readSetupReport() : null
      })
    })
  }).finally(() => { activeRun = null })

  return activeRun
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
