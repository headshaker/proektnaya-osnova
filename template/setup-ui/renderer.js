'use strict'

const form = document.querySelector('#setup-form')
const panels = [...document.querySelectorAll('[data-step-panel]')]
const indicators = [...document.querySelectorAll('[data-step-indicator]')]
const backButton = document.querySelector('#back-button')
const nextButton = document.querySelector('#next-button')
const applyButton = document.querySelector('#apply-button')
const notice = document.querySelector('#notice')
const confirmation = document.querySelector('#confirm-plan')
const titleInput = document.querySelector('#title')
const slugInput = document.querySelector('#slug')
const workSystem = document.querySelector('#work-system-type')
const workSystemUrl = document.querySelector('#work-system-url')
const classification = document.querySelector('#data-classification')
const aiGovernance = document.querySelector('#ai-governance-level')
const inspectToolsButton = document.querySelector('#inspect-tools-button')
const obsidianEnabled = document.querySelector('#obsidian-enabled')
const localSyncEnabled = document.querySelector('#local-sync-enabled')
const toolInputs = [...document.querySelectorAll('input[name="aiTools"]')]

const stepCopy = [
  ['Шаг 1 из 6', 'Расскажите о проекте', 'Достаточно рабочего названия. Техническое имя мастер предложит сам.'],
  ['Шаг 2 из 6', 'Выберите способ работы', 'Не нужно подбирать идеальную методологию — выберите ближайший вариант.'],
  ['Шаг 3 из 6', 'Задайте границы контроля', 'Неопределённые допуски останутся открытыми вопросами, а не догадками системы.'],
  ['Шаг 4 из 6', 'Подключите инструменты', 'Выберите одну или несколько нейросетей и, при необходимости, Obsidian.'],
  ['Шаг 5 из 6', 'Освойте рабочий ритм', 'Короткая памятка поможет управлять проектом без Git, терминала и ручного редактирования файлов.'],
  ['Шаг 6 из 6', 'Проверьте план', 'Предварительная проверка ничего не изменила. Применение начнётся только по вашей команде.']
]

const labels = {
  managementProfile: { light: 'Лёгкое управление', standard: 'Основное управление', regulated: 'Регулируемое управление' },
  deliveryApproach: { predictive: 'Работа по подробному плану', incremental: 'Последовательные результаты', adaptive: 'Короткие адаптивные циклы', flow: 'Непрерывный поток', hybrid: 'Гибридный подход' },
  workSystemType: { 'not-configured': 'Пока не выбрана', repository: 'В папке проекта', 'github-issues': 'GitHub Issues', jira: 'Jira', linear: 'Linear', other: 'Другая система' },
  dataClassification: { public: 'Публичные данные', internal: 'Внутренние данные', confidential: 'Конфиденциальные данные', restricted: 'Строго ограниченные данные', 'not-classified': 'Классификация не определена' },
  aiGovernanceLevel: { basic: 'базовый контроль ИИ', standard: 'стандартный контроль ИИ', high: 'повышенный контроль ИИ' },
  aiTools: { chatgpt: 'ChatGPT / Codex', claude: 'Claude Code', gemini: 'Gemini CLI', qwen: 'Qwen Code', deepseek: 'DeepSeek', grok: 'Grok Build' }
}

let currentStep = 0
let slugWasEdited = false
let governanceWasEdited = false
let busy = false
let latestToolInspection = null
let inspectedSelection = ''

function transliterate (value) {
  const map = {
    а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z', и: 'i', й: 'y',
    к: 'k', л: 'l', м: 'm', н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f',
    х: 'h', ц: 'ts', ч: 'ch', ш: 'sh', щ: 'sch', ъ: '', ы: 'y', ь: '', э: 'e', ю: 'yu', я: 'ya'
  }
  return value.toLowerCase().split('').map(character => map[character] ?? character).join('')
    .replace(/[^a-z0-9]+/gu, '-').replace(/^-+|-+$/gu, '').slice(0, 63).replace(/-+$/u, '')
}

function setNotice (message, kind = 'error') {
  notice.textContent = message
  notice.classList.toggle('is-info', kind === 'info')
  notice.hidden = !message
}

function setBusy (value, button = nextButton) {
  busy = value
  for (const control of [backButton, nextButton, applyButton, inspectToolsButton]) control.disabled = value
  confirmation.disabled = value
  button.classList.toggle('is-busy', value)
  if (!value && currentStep === panels.length - 1) applyButton.disabled = !confirmation.checked
}

function showStep (step) {
  currentStep = Math.max(0, Math.min(step, panels.length - 1))
  panels.forEach((panel, index) => {
    const active = index === currentStep
    panel.hidden = !active
    panel.classList.toggle('is-active', active)
  })
  indicators.forEach((indicator, index) => {
    indicator.classList.toggle('is-active', index === currentStep)
    indicator.classList.toggle('is-complete', index < currentStep)
  })
  document.querySelector('#step-eyebrow').textContent = stepCopy[currentStep][0]
  document.querySelector('#step-title').textContent = stepCopy[currentStep][1]
  document.querySelector('#step-description').textContent = stepCopy[currentStep][2]
  backButton.hidden = currentStep === 0
  nextButton.hidden = currentStep === panels.length - 1
  applyButton.hidden = currentStep !== panels.length - 1
  applyButton.disabled = !confirmation.checked || busy
  document.querySelector('#action-note').textContent = currentStep === panels.length - 1
    ? 'Применение может занять несколько минут'
    : 'Обязательные поля отмечены звёздочкой'
  setNotice('')
  const focusTarget = panels[currentStep].querySelector('input:not([disabled]), select:not([disabled]), summary')
  if (focusTarget) focusTarget.focus()
}

function numberOrNull (selector) {
  const value = document.querySelector(selector).value.trim()
  return value === '' ? null : Number(value)
}

function payload () {
  return {
    title: titleInput.value.trim(),
    slug: slugInput.value.trim(),
    date: document.querySelector('#date').value,
    managementProfile: document.querySelector('#management-profile').value,
    deliveryApproach: document.querySelector('#delivery-approach').value,
    workSystemType: workSystem.value,
    workSystemUrl: workSystemUrl.disabled ? '' : workSystemUrl.value.trim(),
    dataClassification: classification.value,
    aiGovernanceLevel: aiGovernance.value,
    statusCadence: document.querySelector('#status-cadence').value,
    riskCadence: document.querySelector('#risk-cadence').value,
    benefitCadence: document.querySelector('#benefit-cadence').value,
    scheduleToleranceDays: numberOrNull('#schedule-tolerance'),
    costVariancePercent: numberOrNull('#cost-tolerance'),
    scopeChangeRequiresApproval: document.querySelector('#scope-approval').checked,
    githubProtectionMode: document.querySelector('#github-protection').value,
    aiTools: toolInputs.filter(input => input.checked).map(input => input.value),
    obsidianEnabled: obsidianEnabled.checked,
    localSyncEnabled: localSyncEnabled.checked
  }
}

function validateCurrentStep () {
  const fields = [...panels[currentStep].querySelectorAll('input:not([disabled]), select:not([disabled])')]
  for (const field of fields) {
    if (field.id === 'confirm-plan') continue
    if (!field.checkValidity()) {
      field.reportValidity()
      return false
    }
  }
  return true
}

function renderReview (data) {
  document.querySelector('#review-project').textContent = data.title
  document.querySelector('#review-slug').textContent = `${data.slug} · ${data.date}`
  document.querySelector('#review-management').textContent = labels.managementProfile[data.managementProfile]
  document.querySelector('#review-delivery').textContent = labels.deliveryApproach[data.deliveryApproach]
  document.querySelector('#review-work-system').textContent = labels.workSystemType[data.workSystemType]
  document.querySelector('#review-work-url').textContent = data.workSystemUrl || 'Ссылка не задана'
  document.querySelector('#review-data').textContent = labels.dataClassification[data.dataClassification]
  const schedule = data.scheduleToleranceDays === null ? 'срок не определён' : `срок ±${data.scheduleToleranceDays} дн.`
  const cost = data.costVariancePercent === null ? 'стоимость не определена' : `стоимость ±${data.costVariancePercent}%`
  document.querySelector('#review-tolerances').textContent = `${labels.aiGovernanceLevel[data.aiGovernanceLevel]}; ${schedule}; ${cost}`
  const selected = data.aiTools.map(id => labels.aiTools[id])
  document.querySelector('#review-tools').textContent = selected.length > 0 ? selected.join(', ') : 'Нейросети не выбраны'
  const readyCount = latestToolInspection?.tools?.filter(item => item.selected && item.installed).length || 0
  const selectedCount = data.aiTools.length
  const aiStatus = selectedCount === 0 ? 'без инструментов ИИ' : `${readyCount} из ${selectedCount} доступны`
  const obsidianStatus = data.obsidianEnabled
    ? (latestToolInspection?.obsidian?.installed ? 'Obsidian доступен' : 'Obsidian требует установки')
    : 'Obsidian не выбран'
  const syncStatus = data.localSyncEnabled ? 'автообновление включено' : 'автообновление отключено'
  document.querySelector('#review-tools-status').textContent = `${aiStatus}; ${obsidianStatus}; ${syncStatus}`
}

function selectionSignature (data = payload()) {
  return JSON.stringify({ aiTools: data.aiTools, obsidianEnabled: data.obsidianEnabled, date: data.date })
}

function statusElement (id) {
  return document.querySelector(`[data-tool-status="${id}"]`)
}

function setToolStatus (element, text, kind = '') {
  element.textContent = text
  element.classList.toggle('is-ready', kind === 'ready')
  element.classList.toggle('is-missing', kind === 'missing')
}

function renderToolInspection (result) {
  latestToolInspection = result
  inspectedSelection = selectionSignature()
  for (const item of result.tools || []) {
    const element = statusElement(item.id)
    if (!element) continue
    if (!item.selected) setToolStatus(element, 'Не выбрано')
    else if (item.installed) setToolStatus(element, 'Установлено и доступно', 'ready')
    else setToolStatus(element, 'Требуется установка', 'missing')
  }
  const obsidianStatus = statusElement('obsidian')
  if (!result.obsidian?.selected) setToolStatus(obsidianStatus, 'Не выбрано')
  else if (result.obsidian.installed) setToolStatus(obsidianStatus, 'Установлено и доступно', 'ready')
  else setToolStatus(obsidianStatus, 'Требуется установка', 'missing')

  const selectedCount = result.selectedAiTools?.length || 0
  const missing = (result.tools || []).filter(item => item.selected && !item.installed)
  const missingObsidian = result.obsidian?.selected && !result.obsidian?.installed
  const missingCount = missing.length + (missingObsidian ? 1 : 0)
  document.querySelector('#tools-summary').textContent = missingCount === 0
    ? (selectedCount === 0 && !result.obsidian?.selected ? 'Дополнительные инструменты не выбраны.' : 'Все выбранные инструменты доступны.')
    : `Нужно установить: ${missingCount}. Это не помешает подготовить проект.`

  const guidance = document.querySelector('#install-guidance')
  guidance.replaceChildren()
  const addGuidance = (id, name, hint, credential = '') => {
    const item = document.createElement('div')
    item.className = 'install-item'
    const heading = document.createElement('strong')
    heading.textContent = name
    const guide = document.createElement('button')
    guide.type = 'button'
    guide.className = 'guide-button'
    guide.dataset.guideId = id
    guide.textContent = 'Открыть официальную инструкцию'
    item.append(heading)
    if (hint) {
      const command = document.createElement('code')
      command.textContent = hint
      item.append(command)
    }
    if (credential) {
      const note = document.createElement('small')
      note.textContent = credential
      item.append(note)
    }
    item.append(guide)
    guidance.append(item)
  }
  for (const item of (result.tools || []).filter(item => item.selected)) {
    addGuidance(item.id, item.name, item.installed ? '' : item.installHint, item.credential)
  }
  if (missingObsidian) addGuidance('obsidian', 'Obsidian', result.obsidian.installHint)
  guidance.hidden = guidance.childElementCount === 0
}

function markToolsForRecheck () {
  latestToolInspection = null
  inspectedSelection = ''
  document.querySelector('#tools-summary').textContent = 'Выбор изменён. Запустите проверку ещё раз.'
  for (const input of [...toolInputs, obsidianEnabled]) {
    const element = statusElement(input === obsidianEnabled ? 'obsidian' : input.value)
    setToolStatus(element, input.checked ? 'Ожидает проверки' : 'Не выбрано')
  }
  document.querySelector('#install-guidance').hidden = true
}

async function inspectSelectedTools (showProgress = true) {
  const data = payload()
  if (latestToolInspection && inspectedSelection === selectionSignature(data)) return latestToolInspection
  setBusy(true, inspectToolsButton)
  if (showProgress) setNotice('Проверяем выбранные программы. Ничего не устанавливается и не изменяется…', 'info')
  try {
    const result = await window.projectSetup.inspectTools(data)
    renderToolInspection(result)
    if (showProgress) setNotice(result.ready
      ? 'Проверка завершена: выбранные инструменты доступны.'
      : 'Проверка завершена. Недостающие программы можно установить по подсказкам ниже.', 'info')
    return result
  } catch (error) {
    setNotice(error.message || String(error))
    return null
  } finally {
    setBusy(false, inspectToolsButton)
  }
}

async function prepareReview () {
  const data = payload()
  const inspection = await inspectSelectedTools(false)
  if (!inspection) return
  renderReview(data)
  setBusy(true, nextButton)
  setNotice('Выполняется предварительная проверка. Файлы не изменяются…', 'info')
  try {
    const result = await window.projectSetup.preview(data)
    document.querySelector('#preview-output').textContent = result.output || 'Предварительная проверка завершена без сообщений.'
    if (!result.ok) throw new Error(result.output || `Проверка завершилась с кодом ${result.exitCode}.`)
    showStep(5)
  } catch (error) {
    setNotice(error.message || String(error))
  } finally {
    setBusy(false, nextButton)
  }
}

async function applySetup () {
  if (!confirmation.checked || busy) return
  setBusy(true, applyButton)
  setNotice('Проект настраивается и проходит встроенные проверки. Не закрывайте окно…', 'info')
  try {
    const result = await window.projectSetup.apply(payload())
    document.querySelector('#preview-output').textContent = result.output || 'Настройка завершена.'
    if (!result.ok) throw new Error(result.output || `Настройка завершилась с кодом ${result.exitCode}.`)
    const report = result.report
    document.querySelector('#completion-message').textContent = report?.projectTitle
      ? `«${report.projectTitle}» настроен. Теперь можно открыть пульт руководителя и передать ИИ первую задачу.`
      : 'Файлы созданы и прошли встроенные проверки.'
    const decisions = document.querySelector('#completion-decisions')
    decisions.replaceChildren()
    for (const decision of report?.unresolvedDecisions || []) {
      const item = document.createElement('li')
      item.textContent = decision
      decisions.append(item)
    }
    const openObsidianButton = document.querySelector('#open-obsidian-button')
    openObsidianButton.hidden = !(report?.tools?.obsidian?.selected && report?.tools?.obsidian?.installed)
    document.querySelector('#completion').hidden = false
    document.querySelector('#open-home-button').focus()
  } catch (error) {
    setNotice(error.message || String(error))
  } finally {
    setBusy(false, applyButton)
  }
}

titleInput.addEventListener('input', () => {
  if (!slugWasEdited) slugInput.value = transliterate(titleInput.value) || `project-${document.querySelector('#date').value.replaceAll('-', '')}`
})
slugInput.addEventListener('input', () => { slugWasEdited = true })
workSystem.addEventListener('change', () => {
  workSystemUrl.disabled = workSystem.value === 'not-configured'
  if (workSystemUrl.disabled) workSystemUrl.value = ''
})
aiGovernance.addEventListener('change', () => { governanceWasEdited = true })
classification.addEventListener('change', () => {
  if (!governanceWasEdited) aiGovernance.value = ['confidential', 'restricted'].includes(classification.value) ? 'high' : 'standard'
})
confirmation.addEventListener('change', () => { applyButton.disabled = !confirmation.checked || busy })
for (const input of [...toolInputs, obsidianEnabled]) input.addEventListener('change', markToolsForRecheck)
inspectToolsButton.addEventListener('click', async () => { if (!busy) await inspectSelectedTools() })
document.querySelector('#install-guidance').addEventListener('click', async event => {
  const button = event.target.closest('button[data-guide-id]')
  if (!button || busy) return
  try { await window.projectSetup.openGuide(button.dataset.guideId) } catch (error) { setNotice(error.message || String(error)) }
})
document.querySelector('.guidance-panel').addEventListener('click', async event => {
  const button = event.target.closest('button[data-project-guide]')
  if (!button || busy) return
  try { await window.projectSetup.openProjectGuide(button.dataset.projectGuide) } catch (error) { setNotice(error.message || String(error)) }
})

nextButton.addEventListener('click', async () => {
  if (busy || !validateCurrentStep()) return
  if (currentStep === 4) await prepareReview()
  else showStep(currentStep + 1)
})
backButton.addEventListener('click', () => { if (!busy) showStep(currentStep - 1) })
applyButton.addEventListener('click', applySetup)
document.querySelector('#close-button').addEventListener('click', () => window.close())
document.querySelector('#open-home-button').addEventListener('click', async () => {
  try { await window.projectSetup.openHome() } catch (error) { setNotice(error.message || String(error)) }
})
document.querySelector('#open-obsidian-button').addEventListener('click', async () => {
  try { await window.projectSetup.openObsidian() } catch (error) { setNotice(error.message || String(error)) }
})
form.addEventListener('submit', event => event.preventDefault())

window.projectSetup.getDefaults().then(defaults => {
  document.querySelector('#date').value = defaults.date
  document.querySelector('#runtime-label').textContent = `Electron ${defaults.electronVersion}`
  if (!defaults.canConfigure) {
    setNotice('Этот экземпляр проекта уже настроен. Повторный запуск мастера заблокирован.')
    for (const control of form.elements) control.disabled = true
    nextButton.disabled = true
  }
}).catch(error => setNotice(error.message || String(error)))
