# Fixtures isolated from the main suite; no access to application checkouts.
$revisionFixture = Join-Path $root 'directive-revision'
Put (Join-Path $revisionFixture 'directives/AGENTS.global_ide.md') "# Common fixture`nRevisione 3.0 — 2026-10-19."
Put (Join-Path $revisionFixture 'directives/workstation.template.md') 'Postazione fixture'
$revisionApproval = @{authorization='fixture isolata';files=@{}}
foreach($relative in @('directives/AGENTS.global_ide.md','directives/workstation.template.md')){
    $revisionApproval.files[$relative] = Get-SBFileHash (Join-Path $revisionFixture $relative)
}
Put (Join-Path $revisionFixture 'directives/approved.json') (ConvertTo-SBJson $revisionApproval)
$revision = Get-SBApprovedDirectiveRevision $revisionFixture
Assert ($revision.version -eq '3.0' -and $revision.globalHash.Length -eq 64) 'directives: version derived from the approved texts'
$approvalFixture = Join-Path $root 'directive-approval'
Put (Join-Path $approvalFixture 'directives/AGENTS.global_ide.md') 'Fonte senza revisione'
Put (Join-Path $approvalFixture 'directives/workstation.template.md') 'Postazione'
$fixtureApproval = @{authorization='fixture';files=@{}}
foreach($relative in @('directives/AGENTS.global_ide.md','directives/workstation.template.md')) { $fixtureApproval.files[$relative] = Get-SBFileHash (Join-Path $approvalFixture $relative) }
Put (Join-Path $approvalFixture 'directives/approved.json') (ConvertTo-SBJson $fixtureApproval)
Assert ($null -eq (Get-SBApprovedDirectiveRevision $approvalFixture)) 'directives: approved source without a version produces no markings'
Put (Join-Path $approvalFixture 'directives/AGENTS.global_ide.md') "Revisione 9.9 — 2026-10-19. Non approvata"
Assert ($null -eq (Get-SBApprovedDirectiveRevision $approvalFixture)) 'directives: altered source produces no markings'
