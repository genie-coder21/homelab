# bench-llm.ps1 - benchmark local models on a realistic "answer one application question" request:
# a ~2,000-token JSON context packet in, a JSON-schema-constrained answer out.
# Reports cold load time, prompt-processing tok/s, generation tok/s, total seconds, word count and the answer.
# Run 1 is forced cold (model unloaded first). Use FRESH prompts when comparing: Ollama's prompt cache makes a
# repeated identical prompt show absurd read speeds.
param([string[]]$Models = @('gemma4:12b-it-qat', 'gemma4:26b-a4b-it-qat', 'gpt-oss:20b'), [int]$Runs = 2)
$base = 'http://127.0.0.1:11434'

# Entirely fictional applicant and job. The test that matters: does the model invent experience
# that is not in `applicant`?
$packet = @{
  task  = 'Answer one job-application question in the applicant''s voice.'
  rules = @('First person, plain and specific; no flattery, no buzzword soup.',
            'Only claim experience that appears in `applicant` - never invent employers, numbers, certifications, clearances or dates.',
            'Respect `limits` exactly.',
            'If the question cannot be answered truthfully from the applicant data, return {"answer": null, "reason": "..."}.')
  question = @{ text = 'Considering the technologies in the job description, which have you used and how?'; kind = 'textarea'; required = $true }
  limits = @{ max_words = 150; max_chars = 1000 }
  job = @{ title = 'Systems Administrator'; company = 'Example Corp'; location = 'Remote'; remote = $true
           description_excerpt = ('We are looking for a Systems Administrator to manage a hybrid Windows/Linux estate: directory services, ' +
             'virtualization hosts, scripting in PowerShell and Bash, patching, monitoring, container-based internal tools, and backup ' +
             'and recovery. Experience with firewalls, VPNs, DNS and DHCP is required. Nice to have: configuration management, ' +
             'infrastructure as code, a public cloud. ') * 6
           matched_keywords = @('powershell', 'docker', 'linux', 'backup', 'vpn') }
  applicant = @{
    headline = 'IT PROFESSIONAL'
    summary  = 'Generalist comfortable across Windows and Linux, networking and automation.'
    experience = @(
      @{ company = 'Example Services Ltd'; title = 'Support Engineer'; start = '2020-01'; end = 'present'
         bullets = @('Maintained a fleet of Linux servers running containerized internal tools.',
                     'Automated workstation setup with PowerShell.',
                     'Ran nightly backups with regular restore tests.') })
    relevant_sentences = @('I document every system I build so someone else can run it.')
    skills = @('PowerShell', 'Bash', 'Docker', 'Linux', 'networking'); certifications = @() }
  style_examples = @(@{ question = 'Why do you want this role?'; answer = 'I like owning systems end to end, from the first install to the runbook.' })
} | ConvertTo-Json -Depth 8

$schema = @{ type = 'object'; properties = @{ answer = @{ type = @('string', 'null') }; confidence = @{ type = 'number' }; reason = @{ type = 'string' } }; required = @('answer', 'confidence') }
$sys = 'You draft job-application answers. Reply ONLY with JSON: {"answer": "...", "confidence": 0.0-1.0} (or answer null + reason). Follow every rule in the packet.'

foreach ($m in $Models) {
    for ($r = 1; $r -le $Runs; $r++) {
        if ($r -eq 1) { $null = Invoke-RestMethod -Method Post "$base/api/generate" -Body (@{ model = $m; keep_alive = 0 } | ConvertTo-Json) -ContentType 'application/json' }
        $body = @{ model = $m; stream = $false; format = $schema; think = $false
                   options = @{ temperature = 0.6; num_ctx = 16384 }
                   messages = @(@{ role = 'system'; content = $sys }, @{ role = 'user'; content = $packet }) }
        if ($m -like 'gpt-oss*') { $body.think = 'low' }                    # gpt-oss always reasons; keep it short
        $t0 = Get-Date
        try { $res = Invoke-RestMethod -Method Post "$base/api/chat" -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 10))) -ContentType 'application/json; charset=utf-8' -TimeoutSec 600 }
        catch { "{0} run{1}: ERROR {2}" -f $m, $r, $_.Exception.Message; continue }
        $wall = ((Get-Date) - $t0).TotalSeconds
        $ans = $null; try { $ans = ($res.message.content | ConvertFrom-Json).answer } catch {}
        $words = if ($ans) { ($ans -split '\s+' | Where-Object { $_ }).Count } else { 0 }
        "{0,-24} run{1} {2}: load {3,5:N1}s | read {4,5:N0} tok/s ({5} tok) | write {6,5:N1} tok/s ({7} tok) | total {8,5:N1}s | {9} words" -f `
            $m, $r, $(if ($r -eq 1) { 'cold' } else { 'warm' }), ($res.load_duration / 1e9), ($res.prompt_eval_count / ($res.prompt_eval_duration / 1e9)), $res.prompt_eval_count,
            ($res.eval_count / ($res.eval_duration / 1e9)), $res.eval_count, $wall, $words
        if ($r -eq $Runs) { "    ANSWER: $ans" }
    }
    $ps = (Invoke-RestMethod "$base/api/ps").models | Where-Object name -eq $m
    if ($ps) { "    memory: {0:N1} GB total, {1:N1} GB on GPU ({2:P0})" -f ($ps.size / 1GB), ($ps.size_vram / 1GB), ($ps.size_vram / [math]::Max([double]1, [double]$ps.size)) }
    $null = Invoke-RestMethod -Method Post "$base/api/generate" -Body (@{ model = $m; keep_alive = 0 } | ConvertTo-Json) -ContentType 'application/json'
}
