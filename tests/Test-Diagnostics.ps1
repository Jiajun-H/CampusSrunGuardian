$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$assembly = [Reflection.Assembly]::LoadFile((Join-Path $root 'bin\CampusSrunGuardian.exe'))
$guardian = $assembly.GetType('CampusSrunGuardian')
$credentialsType = $assembly.GetType('Credentials')
$credentials = [Activator]::CreateInstance($credentialsType, $true)
$credentialsType.GetField('Username').SetValue($credentials, 'synthetic-account')
$credentialsType.GetField('Password').SetValue($credentials, 'SyntheticSecret#42')
$credentialsType.GetField('UserType').SetValue($credentials, '')
$record = [System.Collections.Generic.Dictionary[string,object]]::new()
$record['ecode'] = 'E6529'
$record['error_msg'] = "SyntheticSecret#42 synthetic-account 10.0.0.8 0123456789abcdef0123456789abcdef`r`nmore"
$method = $guardian.GetMethod('GetSafePortalDetail', [Reflection.BindingFlags]'NonPublic,Static')
$detail = $method.Invoke($null, @($record, $credentials, 'synthetic-account', '10.0.0.8', $null))
foreach ($forbidden in @('SyntheticSecret#42', 'synthetic-account', '10.0.0.8', '0123456789abcdef0123456789abcdef', "`r", "`n")) {
    if ($detail.Contains($forbidden)) { throw 'Sensitive data or control characters were not removed.' }
}
if (-not $detail.Contains('ecode=E6529')) { throw 'Detailed error code was lost.' }
$session = [System.Collections.Generic.Dictionary[string,object]]::new()
$session['user_name'] = 'synthetic-account'
$session['domain'] = 'nh_wireless_student_dorm'
$compare = $guardian.GetMethod('CompareAccountWithSession', [Reflection.BindingFlags]'NonPublic,Static')
if ($compare.Invoke($null, @($credentials, $session)) -ne 'match') {
    throw 'Internal school domain incorrectly created an account mismatch.'
}
$session['user_name'] = 'another-account'
if ($compare.Invoke($null, @($credentials, $session)) -ne 'different') { throw 'Different account was not detected.' }
$session['user_name'] = 'synthetic-account'
$credentialsType.GetField('UserType').SetValue($credentials, 'explicit-suffix')
if ($compare.Invoke($null, @($credentials, $session)) -ne 'suffix_unavailable') { throw 'An internal realm was confused with an explicit login suffix.' }
$session['user_name'] = 'synthetic-account@explicit-suffix'
if ($compare.Invoke($null, @($credentials, $session)) -ne 'match') { throw 'Explicit suffix match was lost.' }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ControlPanel.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Control panel did not parse.' }
foreach ($name in @('Format-PortalDiagnosticText', 'ConvertTo-FriendlyLine')) {
    $definition = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)[0].Extent.Text
    . ([ScriptBlock]::Create($definition))
}
$generic = ConvertTo-FriendlyLine '2026-09-29 20:23:30 [login] Portal rejected login: login_error'
if ($generic.Text -match '核对账号和密码') { throw 'Generic login_error still blames the password.' }
if ($generic.Time -ne '2026-09-29 20:23:30') { throw 'Log date was lost.' }
$specific = ConvertTo-FriendlyLine 'Portal failure detail: ecode=E6529; message=Authentication failed'
if ($specific.Text -notmatch '不能据此判定密码错误') { throw 'E6529 was not explained correctly.' }
Write-Output 'Diagnostics checks passed: internal-domain regression, explicit suffix handling, secret redaction, error details, and historical log dates.'
