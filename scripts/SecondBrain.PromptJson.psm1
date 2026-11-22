#requires -Version 7.5
Set-StrictMode -Version Latest
# Catalog and workflow JSON serializer in the repository style (2 spaces, LF, expanded arrays, literal non-ASCII).
# A catalog read and written back is byte-identical.
$script:SBPromptJsonOptions=[Text.Json.JsonSerializerOptions]::new()
$script:SBPromptJsonOptions.Encoder=[Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping

# Serializer in the repository style (2 spaces, LF, expanded arrays, literal non-ASCII); a catalog read and written back is byte-identical.
function ConvertTo-SBPromptJson($Value,[int]$Depth=0) {
    $pad=' '*(2*($Depth+1)); $end=' '*(2*$Depth)
    if($Value -is [Collections.IDictionary]){
        if($Value.Count -eq 0){return '{}'}
        $parts=foreach($key in $Value.Keys){$pad+[Text.Json.JsonSerializer]::Serialize([string]$key,$script:SBPromptJsonOptions)+': '+(ConvertTo-SBPromptJson $Value[$key] ($Depth+1))}
        return "{`n"+($parts -join ",`n")+"`n$end}"
    }
    if($Value -is [Collections.IList]){
        if($Value.Count -eq 0){return '[]'}
        $parts=foreach($item in $Value){$pad+(ConvertTo-SBPromptJson $item ($Depth+1))}
        return "[`n"+($parts -join ",`n")+"`n$end]"
    }
    if($null -eq $Value){return 'null'}
    if($Value -is [bool]){return $Value.ToString().ToLowerInvariant()}
    if($Value -is [string]){return [Text.Json.JsonSerializer]::Serialize($Value,$script:SBPromptJsonOptions)}
    [string]$Value
}

Export-ModuleMember -Function @('ConvertTo-SBPromptJson')
