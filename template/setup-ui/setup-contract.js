'use strict'

const choices = Object.freeze({
  managementProfile: Object.freeze(['light', 'standard', 'regulated']),
  deliveryApproach: Object.freeze(['predictive', 'incremental', 'adaptive', 'flow', 'hybrid']),
  workSystemType: Object.freeze(['not-configured', 'repository', 'github-issues', 'jira', 'linear', 'other']),
  dataClassification: Object.freeze(['public', 'internal', 'confidential', 'restricted', 'not-classified']),
  aiGovernanceLevel: Object.freeze(['basic', 'standard', 'high']),
  cadence: Object.freeze(['daily', 'weekly', 'biweekly', 'monthly', 'quarterly', 'on-demand']),
  githubProtectionMode: Object.freeze(['auto', 'required', 'disabled'])
})

const allowedKeys = new Set([
  'title', 'slug', 'date', 'managementProfile', 'deliveryApproach', 'workSystemType',
  'workSystemUrl', 'dataClassification', 'aiGovernanceLevel', 'statusCadence',
  'riskCadence', 'benefitCadence', 'scheduleToleranceDays', 'costVariancePercent',
  'scopeChangeRequiresApproval', 'githubProtectionMode'
])

function requiredText (value, name, maximum) {
  if (typeof value !== 'string') throw new Error(`${name}: ожидается текст.`)
  const normalized = value.trim()
  if (!normalized) throw new Error(`${name}: поле не должно быть пустым.`)
  if (normalized.length > maximum || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/u.test(normalized)) {
    throw new Error(`${name}: значение слишком длинное или содержит недопустимые символы.`)
  }
  return normalized
}

function enumValue (value, name, variants) {
  if (!variants.includes(value)) throw new Error(`${name}: выбран неизвестный вариант.`)
  return value
}

function nullableNumber (value, name, maximum, integer = false) {
  if (value === null || value === '' || typeof value === 'undefined') return null
  const parsed = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > maximum || (integer && !Number.isInteger(parsed))) {
    throw new Error(`${name}: укажите неотрицательное ${integer ? 'целое ' : ''}число не больше ${maximum}.`)
  }
  return parsed
}

function isRealIsoDate (value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false
  const date = new Date(`${value}T00:00:00Z`)
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value
}

function validatePayload (source) {
  if (!source || typeof source !== 'object' || Array.isArray(source)) {
    throw new Error('Параметры настройки должны быть объектом.')
  }
  for (const key of Object.keys(source)) {
    if (!allowedKeys.has(key)) throw new Error(`Неизвестный параметр настройки: ${key}.`)
  }

  const title = requiredText(source.title, 'Название проекта', 200)
  const slug = requiredText(source.slug, 'Техническое имя', 63)
  if (!/^[a-z0-9][a-z0-9-]*$/u.test(slug)) {
    throw new Error('Техническое имя: используйте строчные латинские буквы, цифры и дефисы.')
  }
  if (!isRealIsoDate(source.date)) throw new Error('Дата: укажите существующую дату в формате ГГГГ-ММ-ДД.')

  const workSystemType = enumValue(source.workSystemType, 'Рабочая система', choices.workSystemType)
  const workSystemUrl = typeof source.workSystemUrl === 'string' ? source.workSystemUrl.trim() : ''
  if (workSystemUrl && !/^https:\/\//u.test(workSystemUrl)) {
    throw new Error('Ссылка на рабочую систему должна начинаться с https://.')
  }

  return Object.freeze({
    title,
    slug,
    date: source.date,
    managementProfile: enumValue(source.managementProfile, 'Профиль управления', choices.managementProfile),
    deliveryApproach: enumValue(source.deliveryApproach, 'Организация работ', choices.deliveryApproach),
    workSystemType,
    workSystemUrl: workSystemType === 'not-configured' ? '' : workSystemUrl,
    dataClassification: enumValue(source.dataClassification, 'Классификация данных', choices.dataClassification),
    aiGovernanceLevel: enumValue(source.aiGovernanceLevel, 'Контроль ИИ', choices.aiGovernanceLevel),
    statusCadence: enumValue(source.statusCadence, 'Обзор статуса', choices.cadence),
    riskCadence: enumValue(source.riskCadence, 'Обзор рисков', choices.cadence),
    benefitCadence: enumValue(source.benefitCadence, 'Обзор пользы', choices.cadence),
    scheduleToleranceDays: nullableNumber(source.scheduleToleranceDays, 'Допуск по сроку', 36500, true),
    costVariancePercent: nullableNumber(source.costVariancePercent, 'Допуск по стоимости', 100000),
    scopeChangeRequiresApproval: source.scopeChangeRequiresApproval !== false,
    githubProtectionMode: enumValue(source.githubProtectionMode, 'Защита GitHub', choices.githubProtectionMode)
  })
}

function toPowerShellArguments (payload, apply) {
  const value = validatePayload(payload)
  const args = [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', '__SETUP_SCRIPT__',
    '-Title', value.title,
    '-Slug', value.slug,
    '-Date', value.date,
    '-ManagementProfile', value.managementProfile,
    '-DeliveryApproach', value.deliveryApproach,
    '-WorkSystemType', value.workSystemType,
    '-WorkSystemUrl', value.workSystemUrl,
    '-DataClassification', value.dataClassification,
    '-AiGovernanceLevel', value.aiGovernanceLevel,
    '-StatusCadence', value.statusCadence,
    '-RiskCadence', value.riskCadence,
    '-BenefitCadence', value.benefitCadence,
    '-ScopeChangeRequiresApprovalValue', value.scopeChangeRequiresApproval ? 'true' : 'false',
    '-GitHubProtectionMode', value.githubProtectionMode,
    '-NonInteractive'
  ]
  if (value.scheduleToleranceDays !== null) args.push('-ScheduleToleranceDays', String(value.scheduleToleranceDays))
  if (value.costVariancePercent !== null) args.push('-CostVariancePercent', String(value.costVariancePercent))
  if (apply) args.push('-Apply')
  return args
}

module.exports = { choices, isRealIsoDate, toPowerShellArguments, validatePayload }
