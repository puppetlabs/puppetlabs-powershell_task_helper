# pull some more reusable bits from here
# https://github.com/puppetlabs/puppetlabs-bootstrap/blob/master/tasks/windows.ps1
Add-Type -AssemblyName System.ServiceModel.Web, System.Runtime.Serialization

function ConvertTo-JsonString($string)
{
  (($string -replace '\\', '\\') -replace '\"', '\"') -replace '[\u0000-\u001F]', ' '
}

# TODO: polyfill code for PS2 / JSON support
function Write-Stream
{
  PARAM(
    [Parameter(Position=0)]
    $stream,

    [Parameter(ValueFromPipeline=$true)]
    $string
  )

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($string)
  $stream.Write( $bytes, 0, $bytes.Length )
}

function Convert-JsonToXml
{

  PARAM(
    [Parameter(ValueFromPipeline=$true)]
    [string[]]
    $json
  )

  BEGIN
  {
    $mStream = New-Object System.IO.MemoryStream
  }

  PROCESS
  {
    $json | Write-Stream -Stream $mStream
  }

  END
  {
    $mStream.Position = 0
    try
    {
      $jsonReader = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader($mStream,[System.Xml.XmlDictionaryReaderQuotas]::Max)
      $xml = New-Object Xml.XmlDocument
      $xml.Load($jsonReader)
      $xml
    }
    finally
    {
      $jsonReader.Close()
      $mStream.Dispose()
    }
  }
}

Function ConvertFrom-Xml
{
  [CmdletBinding(DefaultParameterSetName="AutoType")]
  PARAM(
    [Parameter(ValueFromPipeline=$true, Mandatory=$true, Position=1)]
    [Xml.XmlNode]
    $xml,

    [Parameter(Mandatory=$true, ParameterSetName="ManualType")]
    [Type]
    $Type,

    [Switch]
    $ForceType
  )

  if (Get-Member -InputObject $xml -Name root)
  {
    return $xml.root.Objects | ConvertFrom-Xml
  }
  elseif (Get-Member -InputObject $xml -Name Objects)
  {
    return $xml.Objects | ConvertFrom-Xml
  }

  $propbag = @{}
  foreach ($name in Get-Member -InputObject $xml -MemberType Properties | Where-Object{$_.Name -notmatch "^__|type"} | Select-Object -ExpandProperty name)
  {
    Write-Debug "$Name Type: $($xml.$Name.type)" -Debug:$false
    $propbag."$Name" = Convert-Properties $xml."$name"
  }

  if (!$Type -and $xml.HasAttribute("__type")) { $Type = $xml.__Type }
  if ($ForceType -and $Type)
  {
    try
    {
      $output = New-Object $Type -Property $propbag
    }
    catch
    {
      $output = New-Object PSObject -Property $propbag
      $output.PsTypeNames.Insert(0, $xml.__type)
    }
  }
  elseif ($propbag.Count -ne 0)
  {
    $output = New-Object PSObject -Property $propbag
    if ($Type)
    {
      $output.PsTypeNames.Insert(0, $Type)
    }
  }
  return $output
}

Function Convert-Properties
{
  PARAM(
    $InputObject
  )

  switch ($InputObject.type)
  {
    'object'  { return (ConvertFrom-Xml -Xml $InputObject) }
    'boolean' { return [bool]::parse($InputObject.get_InnerText()) }
    'null'    { return $null }
    'string'
    {
      $MightBeADate = $InputObject.get_InnerText() -as [DateTime]
      ## Strings that are actually dates (*grumble* JSON is crap)
      if ($MightBeADate -and $propbag."$Name" -eq $MightBeADate.ToString("G"))
      {
        return $MightBeADate
      }
      else
      {
        return $InputObject.get_InnerText()
      }
    }
    'number'
    {
      $number = $InputObject.get_InnerText()
      if ($number -eq ($number -as [int]))
      {
        return $number -as [int]
      }
      elseif ($number -eq ($number -as [double]))
      {
        return $number -as [double]
      }
      else
      {
        return $number -as [decimal]
      }
    }
    'array' {
      [object[]]$Items = $(
        foreach( $item in $InputObject.GetEnumerator() )
        {
          Convert-Properties $item
        }
      )
      return $Items
    }
    default { return $InputObject }
  }
}

Function ConvertFrom-Json2
{
  [CmdletBinding()]
  PARAM(
    [Parameter(ValueFromPipeline=$true,Mandatory=$true,Position=1)]
    [string]
    $InputObject,

    [Parameter(Mandatory=$true)]
    [Type]
    $Type,

    [Switch]
    $ForceType
  )

  $null = $PSBoundParameters.Remove("InputObject")
  [Xml.XmlElement]$xml = (Convert-JsonToXml $InputObject).Root
  if ($xml)
  {
    if ($xml.Objects)
    {
      $xml.Objects.Item.GetEnumerator() | ConvertFrom-Xml @PSBoundParameters
    }
    elseif ($xml.Item -and $xml.Item -isnot [System.Management.Automation.PSParameterizedProperty])
    {
      $xml.Item | ConvertFrom-Xml @PSBoundParameters
    }
    else
    {
      $xml | ConvertFrom-Xml @PSBoundParameters
    }
  }
  else
  {
    Write-Error "Failed to parse JSON with JsonReader" -Debug:$false
  }
}

function ConvertFrom-PSCustomObject
{
  PARAM(
    [Parameter(ValueFromPipeline = $true)]
    $InputObject
  )

  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string])
  {
    $collection = @(
      foreach ($object in $InputObject) { ConvertFrom-PSCustomObject $object }
    )
    $collection
  }
  elseif ($InputObject -is [System.Management.Automation.PSCustomObject])
  {
    $hash = @{}
    foreach ($property in $InputObject.PSObject.Properties)
    {
      $hash[$property.Name] = ConvertFrom-PSCustomObject $property.Value
    }
    $hash
  }
  else
  {
    $InputObject
  }
}

function Get-ContentAsJson
{
  [CmdletBinding()]
  PARAM(
    [Parameter(Mandatory = $true)]
    $Text,

    [Parameter(Mandatory = $false)]
    [Text.Encoding]
    $Encoding = [Text.Encoding]::UTF8
  )

  # using polyfill cmdlet on PS2, so pass type info
  if ($PSVersionTable.PSVersion -lt [Version]'3.0')
  {
    $Text | ConvertFrom-Json2 -Type PSObject | ConvertFrom-PSCustomObject
  }
  else
  {
    $Text | ConvertFrom-Json | ConvertFrom-PSCustomObject
  }
}

# import json, sys

# class TaskError(Exception):
#     def __init__(self, msg, kind, details = None, issue_code = None):
#         super(Exception, self).__init__(msg)
#         self.kind = kind
#         if details:
#             self.details = details
#         else:
#             self.details = {}
#         self.issue_code = issue_code

#     def to_hash(self):
#         result = { 'kind': self.kind, 'msg': self.__str__(), 'details': self.details }
#         if self.issue_code:
#             result['issue_code'] = self.issue_code
#         return result

# class TaskHelper:
#     def task(self, args):
#         raise TaskError(
#             'TaskHelper.task is not implemented',
#             'python.task.helper/exception',
#             {},
#             'EXCEPTION')

#     def run(self):
#         try:
#             args = json.load(sys.stdin)
#             output = self.task(args)
#             print(json.dumps(output))
#         except TaskError as err:
#             print(json.dumps(err.to_hash()))
#             exit(1)
#         except Exception as err:
#             print(json.dumps({
#                 'kind': 'python.task.helper/exception',
#                 'issue_code': 'EXCEPTION',
#                 'msg': err.__str__(),
#                 'details': { 'class': err.__class__.__name__ }
#             }))
#             exit(1)