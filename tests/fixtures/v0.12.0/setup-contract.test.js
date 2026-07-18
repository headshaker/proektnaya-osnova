'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { isRealIsoDate, toPowerShellArguments, validatePayload } = require('../setup-contract')

function validPayload () {
  return {
    title: 'Проект «Север»',
    slug: 'project-sever',
    date: '2026-07-18',
    managementProfile: 'standard',
    deliveryApproach: 'hybrid',
    workSystemType: 'jira',
    workSystemUrl: 'https://jira.example.org/SEVER',
    dataClassification: 'internal',
    aiGovernanceLevel: 'standard',
    statusCadence: 'weekly',
    riskCadence: 'weekly',
    benefitCadence: 'monthly',
    scheduleToleranceDays: 5,
    costVariancePercent: 10.5,
    scopeChangeRequiresApproval: true,
    githubProtectionMode: 'auto'
  }
}

test('принимает полный безопасный набор параметров', () => {
  const result = validatePayload(validPayload())
  assert.equal(result.title, 'Проект «Север»')
  assert.equal(result.scheduleToleranceDays, 5)
  assert.equal(result.costVariancePercent, 10.5)
})

test('отклоняет опасный адрес и неизвестные параметры', () => {
  assert.throws(() => validatePayload({ ...validPayload(), workSystemUrl: 'http://unsafe.example' }), /https:\/\//u)
  assert.throws(() => validatePayload({ ...validPayload(), command: 'Remove-Item' }), /Неизвестный параметр/u)
})

test('отклоняет неверную дату, slug и допуски', () => {
  assert.equal(isRealIsoDate('2026-02-29'), false)
  assert.throws(() => validatePayload({ ...validPayload(), date: '2026-02-29' }), /Дата/u)
  assert.throws(() => validatePayload({ ...validPayload(), slug: '../escape' }), /Техническое имя/u)
  assert.throws(() => validatePayload({ ...validPayload(), scheduleToleranceDays: -1 }), /неотрицательное/u)
})

test('строит массив аргументов без командной оболочки', () => {
  const payload = { ...validPayload(), title: 'Проект & echo unsafe', scopeChangeRequiresApproval: false }
  const args = toPowerShellArguments(payload, true)
  assert.ok(args.includes('Проект & echo unsafe'))
  assert.ok(args.includes('-Apply'))
  assert.ok(args.includes('-ScopeChangeRequiresApprovalValue'))
  assert.ok(args.includes('false'))
  assert.equal(args.filter(value => value === 'Проект & echo unsafe').length, 1)
  assert.deepEqual(args.slice(0, 4), ['-NoLogo', '-NoProfile', '-NonInteractive', '-File'])
})
