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

const stepCopy = [
  ['Шаг 1 из 4', 'Расскажите о проекте', 'Достаточно рабочего названия. Техническое имя мастер предложит сам.'],
  ['Шаг 2 из 4', 'Выберите способ работы', 'Не нужно подбирать идеальную методологию — выберите ближайший вариант.'],
  ['Шаг 3 из 4', 'Задайте границы контроля', 'Неопределённые допуски останутся открытыми вопросами, а не догадками системы.'],
  ['Шаг 4 из 4', 'Проверьте план', 'Предварительная проверка ничего не изменила. Применение начнётся только по вашей команде.']
]

const labels = {
  managementProfile: { light: 'Лёгкое управление', standard: 'Основное управление', regulated: 'Регулируемое управление' },
  deliveryApproach: { predictive: 'Работа по подробному плану', incremental: 'Последовательные результаты', adaptive: 'Короткие адаптивные циклы', flow: 'Непрерывный поток', hybrid: 'Гибридный подход' },
  workSystemType: { 'not-configured': 'Пока не выбрана', repository: 'В папке проекта', 'github-issues': 'GitHub Issues', jira: 'Jira', linear: 'Linear', other: 'Другая система' },
  dataClassification: { public: 'Публичные данные', internal: 'Внутренние данные', confidential: 'Конфиденциальные данные', restricted: 'Строго ограниченные данные', 'not-classified': 'Классификация не определена' },
  aiGovernanceLevel: { basic: 'базовый контроль ИИ', standard: 'стандартный контроль ИИ', high: 'повышенный контроль ИИ' }
}

let currentStep = 0
let slugWasEdited = false
let governanceWasEdited = false
let busy = false

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
  for (const control of [backButton, nextButton, applyButton]) control.disabled = value
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
  document.querySelector('#action-note').textContent = currentStep === 3
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
    githubProtectionMode: document.querySelector('#github-protection').value
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
}

async function prepareReview () {
  const data = payload()
  renderReview(data)
  setBusy(true, nextButton)
  setNotice('Выполняется предварительная проверка. Файлы не изменяются…', 'info')
  try {
    const result = await window.projectSetup.preview(data)
    document.querySelector('#preview-output').textContent = result.output || 'Предварительная проверка завершена без сообщений.'
    if (!result.ok) throw new Error(result.output || `Проверка завершилась с кодом ${result.exitCode}.`)
    showStep(3)
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

nextButton.addEventListener('click', async () => {
  if (busy || !validateCurrentStep()) return
  if (currentStep === 2) await prepareReview()
  else showStep(currentStep + 1)
})
backButton.addEventListener('click', () => { if (!busy) showStep(currentStep - 1) })
applyButton.addEventListener('click', applySetup)
document.querySelector('#close-button').addEventListener('click', () => window.close())
document.querySelector('#open-home-button').addEventListener('click', async () => {
  try { await window.projectSetup.openHome() } catch (error) { setNotice(error.message || String(error)) }
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
