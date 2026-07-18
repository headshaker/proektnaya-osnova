[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Title,
    [string]$Slug,
    [ValidateSet('light', 'standard', 'regulated')]
    [string]$ManagementProfile,
    [ValidateSet('predictive', 'incremental', 'adaptive', 'flow', 'hybrid')]
    [string]$DeliveryApproach,
    [ValidateSet('not-configured', 'repository', 'github-issues', 'jira', 'linear', 'other')]
    [string]$WorkSystemType,
    [string]$WorkSystemUrl = '',
    [ValidateSet('public', 'internal', 'confidential', 'restricted', 'not-classified')]
    [string]$DataClassification,
    [ValidateSet('basic', 'standard', 'high')]
    [string]$AiGovernanceLevel,
    [ValidateSet('daily', 'weekly', 'biweekly', 'monthly', 'quarterly', 'on-demand')]
    [string]$StatusCadence,
    [ValidateSet('daily', 'weekly', 'biweekly', 'monthly', 'quarterly', 'on-demand')]
    [string]$RiskCadence,
    [ValidateSet('daily', 'weekly', 'biweekly', 'monthly', 'quarterly', 'on-demand')]
    [string]$BenefitCadence,
    [Nullable[int]]$ScheduleToleranceDays,
    [Nullable[decimal]]$CostVariancePercent,
    [bool]$ScopeChangeRequiresApproval = $true,
    [ValidateSet('true', 'false')]
    [string]$ScopeChangeRequiresApprovalValue,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [ValidateSet('auto', 'required', 'disabled')]
    [string]$GitHubProtectionMode = 'auto',
    [switch]$NonInteractive,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Assert-IsoDate([string]$Value) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw 'Дата должна существовать и иметь формат ГГГГ-ММ-ДД.'
    }
}

function ConvertTo-ProjectSlug([string]$Value) {
    $map = @{
        'а'='a'; 'б'='b'; 'в'='v'; 'г'='g'; 'д'='d'; 'е'='e'; 'ё'='e'; 'ж'='zh';
        'з'='z'; 'и'='i'; 'й'='y'; 'к'='k'; 'л'='l'; 'м'='m'; 'н'='n'; 'о'='o';
        'п'='p'; 'р'='r'; 'с'='s'; 'т'='t'; 'у'='u'; 'ф'='f'; 'х'='h'; 'ц'='ts';
        'ч'='ch'; 'ш'='sh'; 'щ'='sch'; 'ъ'=''; 'ы'='y'; 'ь'=''; 'э'='e'; 'ю'='yu'; 'я'='ya'
    }
    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $Value.ToLowerInvariant().ToCharArray()) {
        $key = [string]$character
        if ($map.ContainsKey($key)) { [void]$builder.Append($map[$key]); continue }
        [void]$builder.Append($character)
    }
    $slugValue = ($builder.ToString() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slugValue)) { $slugValue = "project-$($Date.Replace('-', ''))" }
    if ($slugValue.Length -gt 63) { $slugValue = $slugValue.Substring(0, 63).TrimEnd('-') }
    return $slugValue
}

function Read-Choice(
    [string]$Prompt,
    [System.Collections.Specialized.OrderedDictionary]$Options,
    [string]$DefaultValue
) {
    Write-Host ''
    Write-Host $Prompt
    $keys = @($Options.Keys)
    for ($index = 0; $index -lt $keys.Count; $index++) {
        $value = [string]$keys[$index]
        $suffix = if ($value -ceq $DefaultValue) { ' (по умолчанию)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($index + 1), $Options[$value], $suffix)
    }
    while ($true) {
        $answer = (Read-Host 'Введите номер').Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultValue }
        [int]$number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $keys.Count) {
            return [string]$keys[$number - 1]
        }
        Write-Host 'Введите номер одного из предложенных вариантов.'
    }
}

function Read-OptionalInteger([string]$Prompt) {
    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        [int]$number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 0) { return $number }
        Write-Host 'Введите целое неотрицательное число или нажмите Enter.'
    }
}

function Read-OptionalDecimal([string]$Prompt) {
    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        [decimal]$number = 0
        $styles = [System.Globalization.NumberStyles]::Number
        $parsed = [decimal]::TryParse(
            $answer, $styles, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$number
        )
        if ($parsed -and $number -ge 0) {
            return $number
        }
        $parsed = [decimal]::TryParse(
            $answer, $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number
        )
        if ($parsed -and $number -ge 0) {
            return $number
        }
        Write-Host 'Введите неотрицательное число или нажмите Enter.'
    }
}

Assert-IsoDate $Date

if (-not [string]::IsNullOrWhiteSpace($ScopeChangeRequiresApprovalValue)) {
    $ScopeChangeRequiresApproval = $ScopeChangeRequiresApprovalValue -ceq 'true'
}

$readmePath = Join-Path $root 'README.md'
if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) { throw 'Не найден README.md шаблона.' }
$readme = [System.IO.File]::ReadAllText($readmePath)
if ($readme -notmatch '\{\{PROJECT_TITLE\}\}') {
    throw 'Проект уже инициализирован. Этот мастер предназначен только для новой копии шаблона.'
}

if ([string]::IsNullOrWhiteSpace($Title)) {
    if ($NonInteractive) { throw 'В неинтерактивном режиме укажите -Title.' }
    $Title = (Read-Host 'Как называется проект?').Trim()
}
if ([string]::IsNullOrWhiteSpace($Title)) { throw 'Название проекта не должно быть пустым.' }
if ($Title.Length -gt 200 -or $Title -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
    throw 'Название проекта содержит недопустимые символы или превышает 200 знаков.'
}

$suggestedSlug = ConvertTo-ProjectSlug $Title
if ([string]::IsNullOrWhiteSpace($Slug)) {
    if ($NonInteractive) { $Slug = $suggestedSlug }
    else {
        $answer = (Read-Host "Короткое техническое имя [$suggestedSlug]").Trim()
        $Slug = if ([string]::IsNullOrWhiteSpace($answer)) { $suggestedSlug } else { $answer }
    }
}
if ($Slug -notmatch '^[a-z0-9][a-z0-9-]*$' -or $Slug.Length -gt 63) {
    throw 'Техническое имя должно содержать до 63 строчных латинских букв, цифр и дефисов.'
}

$profileOptions = [ordered]@{
    light = 'Лёгкий — небольшой проект или низкая цена ошибки'
    standard = 'Основной — обычная продуктовая или инженерная работа'
    regulated = 'Регулируемый — повышенные правовые, финансовые или отраслевые требования'
}
$deliveryOptions = [ordered]@{
    predictive = 'Предсказуемый — подробный план и контроль отклонений'
    incremental = 'Инкрементальный — последовательные полезные результаты'
    adaptive = 'Адаптивный — короткие циклы с уточнением курса'
    flow = 'Поток — непрерывная работа с ограничением незавершённых задач'
    hybrid = 'Гибридный — контрольные рубежи и адаптивное выполнение'
}
$workOptions = [ordered]@{
    'not-configured' = 'Пока не выбрано'
    repository = 'В папке проекта'
    'github-issues' = 'GitHub Issues'
    jira = 'Jira'
    linear = 'Linear'
    other = 'Другая система'
}
$classificationOptions = [ordered]@{
    public = 'Публичные данные'
    internal = 'Внутренние данные организации'
    confidential = 'Конфиденциальные данные'
    restricted = 'Данные с наиболее строгим ограничением доступа'
    'not-classified' = 'Пока не определено — требуется решение владельца'
}

if ([string]::IsNullOrWhiteSpace($ManagementProfile)) {
    $ManagementProfile = if ($NonInteractive) { 'standard' } else { Read-Choice 'Насколько строгим должно быть управление?' $profileOptions 'standard' }
}
if ([string]::IsNullOrWhiteSpace($DeliveryApproach)) {
    $DeliveryApproach = if ($NonInteractive) { 'hybrid' } else { Read-Choice 'Как организована поставка результата?' $deliveryOptions 'hybrid' }
}
if ([string]::IsNullOrWhiteSpace($WorkSystemType)) {
    $WorkSystemType = if ($NonInteractive) { 'not-configured' } else { Read-Choice 'Где команда ведёт рабочие задачи?' $workOptions 'not-configured' }
}
if ([string]::IsNullOrWhiteSpace($DataClassification)) {
    $DataClassification = if ($NonInteractive) { 'not-classified' } else { Read-Choice 'Какие данные будут храниться в проекте?' $classificationOptions 'not-classified' }
}

$needsWorkSystemUrl = -not $NonInteractive -and $WorkSystemType -cne 'not-configured' -and [string]::IsNullOrWhiteSpace($WorkSystemUrl)
if ($needsWorkSystemUrl) {
    $WorkSystemUrl = (Read-Host 'Ссылка на рабочую систему (Enter — добавить позже)').Trim()
}

if (-not [string]::IsNullOrWhiteSpace($WorkSystemUrl) -and $WorkSystemUrl -notmatch '^https://') {
    throw 'Адрес рабочей системы должен быть пустым или начинаться с https://.'
}
if ($WorkSystemType -ceq 'not-configured') { $WorkSystemUrl = '' }

if ($null -ne $ScheduleToleranceDays -and $ScheduleToleranceDays -lt 0) {
    throw 'Допустимое отклонение по сроку не может быть отрицательным.'
}
if ($null -ne $CostVariancePercent -and $CostVariancePercent -lt 0) {
    throw 'Допустимое отклонение по стоимости не может быть отрицательным.'
}
if (-not $NonInteractive) {
    if ($null -eq $ScheduleToleranceDays) {
        $ScheduleToleranceDays = Read-OptionalInteger 'Допустимое отклонение по сроку в днях (Enter — решить позже)'
    }
    if ($null -eq $CostVariancePercent) {
        $CostVariancePercent = Read-OptionalDecimal 'Допустимое отклонение по стоимости в процентах (Enter — решить позже)'
    }
}

if ([string]::IsNullOrWhiteSpace($AiGovernanceLevel)) {
    $AiGovernanceLevel = if ($DataClassification -in @('confidential', 'restricted')) { 'high' } else { 'standard' }
}
if ([string]::IsNullOrWhiteSpace($StatusCadence)) { $StatusCadence = 'weekly' }
if ([string]::IsNullOrWhiteSpace($RiskCadence)) { $RiskCadence = 'weekly' }
if ([string]::IsNullOrWhiteSpace($BenefitCadence)) { $BenefitCadence = 'monthly' }

$unresolved = [System.Collections.Generic.List[string]]::new()
if ($WorkSystemType -ceq 'not-configured') { $unresolved.Add('выбрать рабочую систему команды') }
if ($DataClassification -ceq 'not-classified') { $unresolved.Add('определить классификацию данных') }
if ($null -eq $ScheduleToleranceDays -and $null -eq $CostVariancePercent) {
    $unresolved.Add('согласовать допустимые отклонения по сроку и стоимости')
}

Write-Host ''
Write-Host 'План настройки'
Write-Host "  Проект: $Title"
Write-Host "  Техническое имя: $Slug"
Write-Host "  Профиль: $($profileOptions[$ManagementProfile])"
Write-Host "  Организация работ: $($deliveryOptions[$DeliveryApproach])"
Write-Host "  Рабочие задачи: $($workOptions[$WorkSystemType])"
Write-Host "  Данные: $($classificationOptions[$DataClassification])"
Write-Host "  Контроль ИИ: $AiGovernanceLevel"
switch ($GitHubProtectionMode) {
    'auto' { Write-Host '  GitHub: защита main будет настроена автоматически, если репозиторий и права доступны' }
    'required' { Write-Host '  GitHub: настройка защиты main обязательна; ошибка остановит мастер' }
    'disabled' { Write-Host '  GitHub: автоматическая защита отключена явным параметром' }
}
if ($unresolved.Count -gt 0) {
    Write-Host '  После настройки потребуются решения:'
    foreach ($item in $unresolved) { Write-Host "    - $item" }
}

if (-not $Apply) {
    if ($NonInteractive) {
        Write-Host ''
        Write-Host 'Это только план. Для применения добавьте -Apply.'
        return
    }
    $confirmation = (Read-Host 'Применить настройку? [д/Н]').Trim().ToLowerInvariant()
    if ($confirmation -notin @('д', 'да', 'y', 'yes')) {
        Write-Host 'Настройка отменена, файлы не изменены.'
        return
    }
}

& (Join-Path $PSScriptRoot 'init-project.ps1') -Title $Title -Slug $Slug -Date $Date

$configPath = Join-Path $root 'PROJECT-CONFIG.json'
$config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
$config.projectSlug = $Slug
$config.managementProfile = $ManagementProfile
$config.deliveryApproach = $DeliveryApproach
$config.workSystem.type = $WorkSystemType
$config.workSystem.url = $WorkSystemUrl
$config.reviewCadence.status = $StatusCadence
$config.reviewCadence.risks = $RiskCadence
$config.reviewCadence.benefits = $BenefitCadence
$config.tolerances.scheduleDays = $ScheduleToleranceDays
$config.tolerances.costVariancePercent = $CostVariancePercent
$config.tolerances.scopeChangeRequiresApproval = $ScopeChangeRequiresApproval
$config.dataClassification = $DataClassification
$config.aiGovernanceLevel = $AiGovernanceLevel
$config.configuredAt = $Date

$temporaryConfig = "$configPath.setup-$PID.tmp"
try {
    [System.IO.File]::WriteAllText($temporaryConfig, ($config | ConvertTo-Json -Depth 10) + "`n", $utf8)
    Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Force }
}

& (Join-Path $PSScriptRoot 'build-status.ps1')
& (Join-Path $PSScriptRoot 'check-project-health.ps1')
& (Join-Path $PSScriptRoot 'build-project-dossier.ps1')
& (Join-Path $PSScriptRoot 'build-project-dossier.ps1') -Check
& (Join-Path $PSScriptRoot 'validate-registries.ps1') -ProjectPath $root
& (Join-Path $PSScriptRoot 'validate-vault.ps1')

$githubProtectionFailure = $null
if ($GitHubProtectionMode -ceq 'disabled') {
    $githubProtection = [pscustomobject][ordered]@{
        schemaVersion = 1
        status = 'disabled'
        reasonCode = 'disabled-by-parameter'
        message = 'Автоматическая защита GitHub отключена явным параметром.'
        repository = ''
        canonicalBranch = 'main'
        rulesetName = 'Проектная основа: единая версия'
        requiredStatusCheck = 'Одна согласованная версия проекта'
        action = 'none'
        rulesetId = $null
        rulesetUrl = ''
    }
}
else {
    try {
        $protectionParameters = @{ Apply = $true }
        if ($GitHubProtectionMode -ceq 'auto') { $protectionParameters.AllowPending = $true }
        $githubProtection = & (Join-Path $PSScriptRoot 'configure-github-protection.ps1') @protectionParameters
    }
    catch {
        $githubProtectionFailure = $_
        $githubProtection = [pscustomobject][ordered]@{
            schemaVersion = 1
            status = 'failed'
            reasonCode = 'github-configuration-failed'
            message = $_.Exception.Message
            repository = ''
            canonicalBranch = 'main'
            rulesetName = 'Проектная основа: единая версия'
            requiredStatusCheck = 'Одна согласованная версия проекта'
            action = 'retry-required'
            rulesetId = $null
            rulesetUrl = ''
        }
    }
}

if ([string]$githubProtection.status -in @('pending', 'failed')) {
    $unresolved.Add('завершить автоматическую настройку защиты GitHub')
}

$reportDirectory = Join-Path $root '.project'
[System.IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
$report = [ordered]@{
    schemaVersion = 1
    result = if ([string]$githubProtection.status -in @('pending', 'failed')) { 'partial' } else { 'success' }
    configuredAt = $Date
    projectTitle = $Title
    projectSlug = $Slug
    unresolvedDecisions = @($unresolved)
    githubProtection = $githubProtection
    nextDocument = 'HOME.md'
}
[System.IO.File]::WriteAllText(
    (Join-Path $reportDirectory 'setup-report.json'),
    ($report | ConvertTo-Json -Depth 5) + "`n",
    $utf8
)

Write-Host ''
if ($report.result -ceq 'success') {
    Write-Host 'Готово: проект настроен и прошёл проверки.'
}
else {
    Write-Warning 'Проект настроен, но защита GitHub требует завершения.'
    Write-Host 'После входа в gh с правами администратора выполните:'
    Write-Host '  pwsh ./scripts/configure-github-protection.ps1 -Apply'
}
Write-Host 'Следующий шаг: откройте HOME.md и передайте ИИ первую задачу из START-HERE.md.'
if ($unresolved.Count -gt 0) {
    Write-Host 'Требуют решения владельца:'
    foreach ($item in $unresolved) { Write-Host "  - $item" }
}
if ($null -ne $githubProtectionFailure) {
    throw "Проект создан, но обязательная защита GitHub не настроена: $($githubProtectionFailure.Exception.Message)"
}
