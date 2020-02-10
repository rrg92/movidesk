#Requires -Version 3
param(
	$DebugMode = $false
	,$ResetStorage = $false
)

$ErrorActionPreference = "Stop";

if($ResetStorage){
	$Global:PsMoviDesk_Storage = $null;
}

## Global Var storing important values!
	if($Global:PsMoviDesk_Storage -eq $null){
		$Global:PsMoviDesk_Storage = @{
				SESSIONS = @{
				
						#SessionID:
						#URL|token;
						SessionID  = @{
							
						}
					
					}
					
					
				DEFAULT_SESSION = $null
			}			
	}


## Helpers
#Make calls to a zabbix server url api.
	Function verbose {
		$ParentName = (Get-Variable MyInvocation -Scope 1).Value.MyCommand.Name;
		write-verbose ( $ParentName +':'+ ($Args -Join ' '))
	}
	
	Function Movidesk_UrlEncode {
			param($Value)
			
			try {
				$Encoded =  [Uri]::EscapeDataString($Value);
				return $Encoded;
			} catch {
				write-verbose "Failure on urlencode. Data:$Value. Error:$_";
				return $Value;
			}
		}
	
	#Converts a hashtable to a URLENCODED format to be send over HTTP requests.
	Function Movidesk_BuildURLEncoded {
		param($Data)
		
		
		$FinalString = @();
		$Data.GetEnumerator() | %{
			write-verbose "$($MyInvocation.InvocationName): Converting $($_.Key)..."
			$ParamName = MoviDesk_UrlEncode $_.Key; 
			$ParamValue = Movidesk_UrlEncode $_.Value; 
		
			$FinalString += "$ParamName=$ParamValue";
		}

		$FinalString = $FinalString -Join "&";
		return $FinalString;
	}
	
	#Thanks to https://ss64.com/ps/left.html
	Function Movidesk_left {
	   [CmdletBinding()]
	 
	   Param (
		  [Parameter(Position=0, Mandatory=$True,HelpMessage="Enter a string of text")]
		  [String]$text,
		  [Parameter(Mandatory=$True)]
		  [Int]$Length
	   )
		return  $text.SubString(0, [math]::min($Length,$text.length))
	}
	
	Function Movidesk_Convert2Localtime {
		param($textDatetime)
		
		#Enforces that we have a full date with 7 places in milliseconds.
		$DtString = Movidesk_left -text ($textDatetime + ("0"*7)) -length 27
					
		return [datetime]::ParseExact($DtString, 'yyyy-MM-ddTHH:mm:ss.fffffff', $null).ToLocalTime()
	}
	
	
	Function Movidesk_CallUrl {
		[CmdLetBinding()]
		param(
			$url 			= $null
			,[object]$data 	= $null
			,$method 		= "POST"
			,$contentType 	= "application/json"
		)
		$ErrorActionPreference = "Stop";

		try {
		
			#building the request parameters
			if($method -eq 'GET' -and $data){
				if($data -is [hashtable]){
						$QueryString = Movidesk_BuildURLEncoded $data;
				} else {
						$QueryString = $data;
				}
				
				if($url -like '*?*'){
					$url += '&' + $QueryString
				} else {
					$url += '?' + $QueryString;
				}
			}
		
			verbose "  Creating WebRequest method... Url: $url. Method: $Method ContentType: $ContentType";
			$Web = [System.Net.WebRequest]::Create($url);
			$Web.Method = $method;
			$Web.ContentType = $contentType
			
			#building the body..
			if($data -and 'POST','PATCH','PUT' -Contains $method){
				if($data -is [hashtable]){
					verbose "Converting input object to json string..."
					$data = Movidesk_ConvertToJson $data;
				}
		
				#Determina a quantidade de bytes...
				[Byte[]]$bytes = [byte[]][char[]]$data;
				
				#Escrevendo os dados
				$Web.ContentLength = $bytes.Length;
				verbose "  Bytes lengths: $($Web.ContentLength)"
				
				
				verbose "  Getting request stream...."W
				$RequestStream = $Web.GetRequestStream();
				
				
				try {
					verbose "  Writing bytes to the request stream...";
					$RequestStream.Write($bytes, 0, $bytes.length);
				} finally {
					verbose "  Disposing the request stream!"
					$RequestStream.Dispose() #This must be called after writing!
				}
			}
			
			
			$UrlUri = [uri]$Url;
			$Unescaped  = $UrlUri.Query.split("&") | %{ [uri]::UnescapeDataString($_) }
			verbose "Query String:`r`n$($Unescaped | out-string)"
			
			verbose "  Making http request... Waiting for the response..."
			$HttpResp = $Web.GetResponse();
			
			
			$responseString  = $null;
			
			if($HttpResp){
				verbose "  charset: $($HttpResp.CharacterSet) encoding: $($HttpResp.ContentEncoding). ContentType: $($HttpResp.ContentType)"
				verbose "  Getting response stream..."
				$ResponseStream  = $HttpResp.GetResponseStream();
				
				verbose "  Response stream size: $($ResponseStream.Length) bytes"
				
				$IO = New-Object System.IO.StreamReader($ResponseStream);
				
				verbose "  Reading response stream...."
				$responseString = $IO.ReadToEnd();
				
				verbose "  response json is: $responseString"
			}
			
			
			verbose "  Response String size: $($responseString.length) characters! "
			return $responseString;
		} finally {
			if($IO){
				$IO.close()
			}
			
			if($ResponseStream){
				$ResponseStream.Close()
			}

			if($RequestStream){
				write-verbose "Finazling request stream..."
				$RequestStream.Close()
			}
		}
	
	
	}

	Function Movidesk_TranslateResponseJson {
		param($Response)
		
		#Converts the response to a object.
		verbose " Converting from JSON!"
		$ResponseO = Movidesk_ConvertFromJson $Response;
		
		verbose " Checking properties of converted result!"
		#Check outputs
		<#
		if($ResponseO.Error -ne $null){
			$ResponseError = $ResponseO.Error;
			$MessageException = "[$($ResponseError.ErrorCode)]: $($ResponseError.ErrorMessage)";
			$Exception = New-Object System.Exception($MessageException)
			$Exception.Source = "OtrsGenericInterface"
			throw $Exception;
			return;
		}
		#>
		
		
		#If not error, then return response result.
		if($ResponseO -is [hashtable]){
			return (New-Object PsObject -Prop $ResponseO);
		} else {
			return $ResponseO;
		}
	}

	#Converts objets to JSON and vice versa,
	Function Movidesk_ConvertToJson($o) {
		
		if(Get-Command ConvertTo-Json -EA "SilentlyContinue"){
			verbose " Using ConvertTo-Json"
			return Movidesk_EscapeNonUnicodeJson(ConvertTo-Json $o -Depth 10);
		} else {
			verbose " Using javascriptSerializer"
			Movidesk_LoadJsonEngine
			$jo=new-object system.web.script.serialization.javascriptSerializer
			$jo.maxJsonLength=[int32]::maxvalue;
			return Movidesk_EscapeNonUnicodeJson ($jo.Serialize($o))
		}
	}

	Function Movidesk_ConvertFromJson([string]$json) {
	
		if(Get-Command ConvertFrom-Json  -EA "SilentlyContinue"){
			verbose " Using ConvertFrom-Json"
			ConvertFrom-Json $json;
		} else {
			verbose " Using javascriptSerializer"
			Movidesk_LoadJsonEngine
			$jo=new-object system.web.script.serialization.javascriptSerializer
			$jo.maxJsonLength=[int32]::maxvalue;
			return $jo.DeserializeObject($json);
		}
		

	}
	
	Function Movidesk_CheckAssembly {
		param($Name)
		
		if($Global:PsMovidesk_Loaded){
			return $true;
		}
		
		if( [appdomain]::currentdomain.getassemblies() | ? {$_ -match $Name}){
			$Global:PsMovidesk_Loaded = $true
			return $true;
		} else {
			return $false
		}
	}
	
	Function Movidesk_LoadJsonEngine {

		$Engine = "System.Web.Extensions"

		if(!(Movidesk_CheckAssembly $Engine)){
			try {
				verbose " Loading JSON engine!"
				Add-Type -Assembly  $Engine
				$Global:PsMovidesk_Loaded = $true;
			} catch {
				throw "ERROR_LOADIING_WEB_EXTENSIONS: $_";
			}
		}

	}

	#Troca caracteres não-unicode por um \u + codigo!
	#Solucao adapatada da resposta do Douglas em: http://stackoverflow.com/a/25349901/4100116
	Function Movidesk_EscapeNonUnicodeJson {
		param([string]$Json)
		
		$Replacer = {
			param($m)
			
			return [string]::format('\u{0:x4}', [int]$m.Value[0] )
		}
		
		$RegEx = [regex]'[^\x00-\x7F]';
		verbose "  Original Json: $Json";
		$ReplacedJSon = $RegEx.replace( $Json, $Replacer)
		verbose "  NonUnicode Json: $ReplacedJson";
		return $ReplacedJSon;
	}
	
	#Thanks to CosmosKey answer in https://stackoverflow.com/questions/7468707/deep-copy-a-dictionary-hashtable-in-powershell
	function Movidesk_CloneObject {
		param($DeepCopyObject)
		$memStream = new-object IO.MemoryStream
		$formatter = new-object Runtime.Serialization.Formatters.Binary.BinaryFormatter
		$formatter.Serialize($memStream,$DeepCopyObject)
		$memStream.Position=0
		$formatter.Deserialize($memStream)
	}
	

	
## API Implentantions
	

	Function Get-MovideskTicket {
		[CmdLetBinding()]
		param(
			 [int[]]$id = $null
			,[string[]]$select = "id,subject,status,createdDate,owner,ownerTeam,createdBy,resolvedIn,tags,origin"
			
			,#ticket base status
				[string[]]
				[ValidateSet("New","InAttendance","Stopped","Canceled","Resolved","Closed")]
				$BaseStatus  		= $null
				
			,[string]$StartCreateDate  	= $null
			,[string]$EndCreateDate  	= $null
			
			,#Filter by id of person who create. Use Get-MovideskPerson 
				$createdBy = $null
				
			,#Filter by id of person who requested. Use Get-MovideskPerson 
				$clients	= $null
				
			,#Filter by id of person who owns. Use Get-MovideskPerson 
				$owner		= $null
			
			#Specify same set of aceptable parameters
			,$FilterCustom = $null
			
			,$top = $null
			
			,$tags = @()
			
			
			,#get actions
				[switch]$IncludeActions
				
			,#get actions
				[switch]$IncludeTimesAppointments
			
			,#Filter only open tickets. This is a shorcut for New, InAttendance and Open.
				[switch]$OpenOnly
				
			,[switch]
				$Force
				
			,[switch]
				$RawResult 
		)
		
		$Params = @{
			DoRequest 	= $true
			endpoint	= 'tickets'
			select		= $select
			expand		= 'createdBy,owner,clients'
		}
		
		if($IncludeActions){
			$Params.expand += ',actions';
		}	
		
		if($IncludeTimesAppointments){
			$Params.expand += ',actions($expand=timeAppointments($expand=createdBy))';
		}
		
		if($top -is [int]){
			$Params['top'] = $top;
		}
		
		$AllFilter = @();
		
		if($id){
			$idFilter = @($id | %{"id eq $_"}) -Join " or ";
			$AllFilter += "($idFilter)";
		}
		
		if($OpenOnly -and !$BaseStatus){
			$baseStatus = @("New","InAttendance","Stopped")
		}
		
		
		if($BaseStatus){
			$baseStatusFilter = @($BaseStatus | %{"baseStatus eq '$_'"}) -Join " or "
			$AllFilter += "($baseStatusFilter)"
		}
		
		if($StartCreateDate){
			#"2016-11-18T14:25:07.1920886"
			$AllFilter += "createdDate ge " + ([datetime]$StartCreateDate).ToUniversalTime().toString("yyyy-MM-ddTHH:mm:ss.ff\z")
		}
		
		if($EndCreateDate){
			#"2016-11-18T14:25:07.1920886"
			$AllFilter += "createdDate le " + ([datetime]$EndCreateDate).ToUniversalTime().toString("yyyy-MM-ddTHH:mm:ss.ff\z")
		}
		
		
		if($owner){
			#Must be a id or contains a id property!
			$OwnerFilter = @($owner | %{
					#Check if in id property or itself a id!
					if($_.id){
						$_.id;
					} else {
						$_
					}
				} | %{
					"owner/id eq '$_'"
				}
			) -Join " or ";
			
			$AllFilter += "($OwnerFilter)"
		}
		
		if($client){
			#Must be a id or contains a id property!
			$ClientFilter = @($client | %{
					#Check if in id property or itself a id!
					if($_.id){
						$_.id;
					} else {
						$_
					}
				} | %{
					"clients/any(c: c/id eq '$_')"
				}
			) -Join " or ";
			
			$AllFilter += "($ClientFilter)"
		}
		
		if($tags){
			$TagsFilter  = @($tags | %{"tags/any(t: t eq '$_')"}) -Join " or ";
			$AllFilter += "($TagsFilter)";
		}	



		###gather all flters!
		if($AllFilter){
			$Params['filter'] = $AllFilter -Join " and ";
		} else {
			if(!$Force){
				write-host "You dont specify no filter. Use -Force to ack this.";
				return;
			}
		}
		
		$r = New-MovideskRequest @Params;
		
		if($RawResult){
			return $r;
		}
		
		if($r){
			$r | %{
				if($_.createdDate){
					$_.createdDate = Movidesk_Convert2Localtime $_.createdDate
				}
				
				if($_.resolvedIn){
					$_.resolvedIn = Movidesk_Convert2Localtime $_.resolvedIn
				}
				
				if($_.owner){
					$_ | Add-Member -Type Noteproperty -Name ownerName -Value $_.owner.businessName;
				}
				
				if($_.clients){
					$ClientList = @($_.clients | %{$_.businessName}) -Join ",";
					
					$_ | Add-Member -Type Noteproperty -Name ClientsNames -Value $ClientList;
				}
			}
			return $r;
		}
	}

	Function Get-MovideskPerson {
		[CmdLetBinding()]
		param(
			 [string[]]$id = $null
			
			,#ticket base status
				[string[]]
				$Name
				
			,#ticket base status
				[string[]]
				$Email
				
				
			,#ticket base status
				[string[]]
				[ValidateSet('1',"Pessoa"
							,'2',"Empresa"
							,'3',"Departamento"
							)]
				$Type
				
			,#ticket base status
				[string[]]
				$Teams
				
			,[string[]]$select = "id,personType,profileType,businessName,corporateName,userName,emails"
			,$expand = 'emails'
			
			
			#Specify same set of aceptable parameters
			,$FilterCustom = $null
			
			
			,$top = $null
				
			,[switch]
				$Force
				
			,[switch]
				$RawResult 
		)
		
		$Params = @{
			DoRequest 	= $true
			endpoint	= 'persons'
			select		= $select
			expand		= $expand
		}

		$PERSON_TYPES = @{
			1 	= 'Pessoa'
			2	= 'Empresa'
			3	= 'Departamento'
		}
		
		if($top -is [int]){
			$Params['top'] = $top;
		}
		
		$AllFilter = @();
		
		if($id){
			$idFilter = @($id | %{"id eq '$_'"}) -Join " or ";
			$AllFilter += "($idFilter)";
		}
		
		if($Name){
			$NameFilter = @($Name | %{"startswith(businessName,'$_')"}) -Join " or ";
			$AllFilter  += "($NameFilter)";
		}
		
		if($Email){
			$EmailFilter = @($Email | %{"Emails/any(e: e/email eq '$_')"}) -Join " or ";
			$AllFilter  += "($EmailFilter)";
		}
		
		if($Type){
		
			$PersonTypeFilter = @(
				$Type | %{
					if($_ -match '\d+'){
						#output the number!
						$_
					} else {
						#Is a text, get numeric value...
						$TypeName = $_;
						$PERSON_TYPES.GetEnumerator() | ?{ $_.Value -eq $TypeName } | %{$_.key};
					}
				} | %{ "personType eq $_" }
			) -Join " or ";
			
			$AllFilter += "($PersonTypeFilter)"
		}
		
		if($Teams){
		
			$TeamsFilter = @(
				$Teams | %{ "teams/any(t: t eq '$_')" }
			) -Join " or ";
			
			$AllFilter += "($TeamsFilter)"
		}
		
		if($AllFilter){
			$Params['filter'] = $AllFilter -Join " and ";
		}
		
			
		$r = New-MovideskRequest @Params;
		
		if($RawResult){
			return $r;
		}
		
		

		
		$r | %{
			if($_.personType){
				$_ | Add-Member -Type Noteproperty -Name personTypeDesc  -Value ($PERSON_TYPES[$_.personType])
			}
			
			if($_.emails){
				$defaultEmail = $_.emails | ? { $_.isDefault };
				$_ | Add-Member -Type Noteproperty -Name email -Value $defaultEmail.email;
			}
			
			

		}	
		
		
		return $r;
	}

	Function New-MovideskTicket {
		
	}

	Function Update-MovideskTicket {
		[CmdletBinding()]
		param(
		
			 $ticket 
			 ,$NewAction
			 ,$subject 
		)
		
		$Params = @{
			DoRequest 	= $true
			data		= $null
			method		= 'PATCH'
			endpoint	= 'tickets'
		}
		
		if(!$ticket.id){
			throw "INVALID_TICKET_ID";
		}
			
		$Params['urlData'] = @{
				id = $ticket.id
			}
		
		$NewTicketUpdate = @{}
		
		if($NewAction){
			$NewTicketUpdate['actions'] = [object[]]@($NewAction);
		}
		
		if($subject){
			$NewTicketUpdate['subject'] = $subject;
		}
		
		
		$Params['data'] = $NewTicketUpdate;
			
		$r = New-MovideskRequest @Params;
	}

	#Creates a new action on some ticket!
	Function New-MovideskTicketAction {
		[CmdletBinding()]
		param(
			$Ticket
			
			,$description
			,$createdBy						= $null
			,[hashtable[]]$timeAppointments = @()
			,[ValidateSet(1,2)]
				$Type = 1
			
			
			#,$attachments
			#,$tags
		)
		
		$ActionsParams = @{
				type 				= $Type
				description			= $description
			}
			
		if(!$createdBy){
			$createdBy = $Ticket.createdBy;
		}
		
		if(!$createdBy){
			throw "NEWACTION_CANNOT_DETERMINE_CREATEDBY";
		}
		
		$ActionsParams['createdBy'] = @{
				id = $createdBy.id
			}
		
		$timeAppointments | %{
			if(!$_.createdBy){
				$_.createdBy = $createdBy
			}
			
			#workHours;
			
			if(!$_.activity){
				throw "EMPTY_APPOINTEMNT_ACTIVITY"
			}
			
			if(!$_.workTypeName){
				$_.workTypeName = "Normal";
			}
			
			if($_.date -is [datetime]){
				$_.date  = $_.date.toString("yyyy-MM-ddT00:00:00")
			} elseif (!$_.date){
				$_.date  = (Get-Date).toString("yyyy-MM-ddT00:00:00")
			}
			
			#Convert date to movideskpart!
			if(-not($_.periodStart -match '^\d\d:\d\d:\d\d$')){
				throw "INVALID_APPOINTEMNT_PERIODSTART"
			}
			
			#Convert date to movideskpart!
			if(-not($_.periodEnd -match '^\d\d:\d\d:\d\d$')){
				throw "INVALID_APPOINTEMNT_PERIODEND"
			}
		
		}
	
	
		if($timeAppointments){
			$ActionsParams['timeAppointments'] = [object[]]@($timeAppointments);
		}
		
		return $ActionsParams;
	}

	
# Facilities!	

#Build request parameters to be used Movidesk_CallUrl
Function New-MovideskRequest {
	[CmdletBinding()]
	param(
		  $endpoint
		 ,$data		= $null
		 ,$method	= 'GET'
		 ,$select	= $null
		 ,$filter	= $null
		 ,$top 		= $null
		 ,$orderby	= $null
		 ,$expand	= $null
		 ,$session	= (Get-MovideskDefaultSession)
		 ,[switch]$DoRequest
		 ,$urlData	= $null
	)

	if(!$session){
		throw "INVALID_SESSION";
	}

	$Token 	= $Session.token;
	$Url	= $Session.url;

	if(!$url){
		throw "INVALID_URL";
	}
	
	if(!$token){
		throw "INVALID_TOKEN";
	}
	
	verbose "Base url: $Url"
	
	$UrlParams = @{
		token = $token;
	}
	
	if($select){
		$UrlParams.add('$select',( $select -Join "," ))
	}
	
	if($orderby){
		$UrlParams.add('$orderby',( $orderby -Join "," ))
	}
	
	if($filter){
		$UrlParams.add('$filter',( $filter  ))
	}
	
	if($top){
		$UrlParams.add('$top',$top)
	}
	
	if($expand){
		$UrlParams.add('$expand',$expand)
	}
	
	if($urlData){
		$UrlParams += $urlData;
	}	
	
	$url = 'https://api.movidesk.com/public/v1/' + $endpoint;
	
	$url += '?' + (Movidesk_BuildURLEncoded $UrlParams)
	
	
	$p = @{
		'url' 		= $url
		'data' 		= $data
		'method' 	= $method
	}
	
	if(!$DoRequest){
		return $p;
	}
	
	try {
		$r = Movidesk_CallUrl @p;
		return (Movidesk_ConvertFromJson $r)
	} catch {
		$WebResp = $_.Exception.GetBaseException().Response;
		
		if($WebResp.StatusCode -eq 404){
			return;
		} else {
			throw;
		}
	}
	
}
	

Function Set-DefaultMovideskSession {
	[CmdLetBinding()]
	param(
		
		[Parameter(Mandatory=$True, ValueFromPipeline=$true)]
		$Session
	
	)
	
	begin {}
	process {}
	end {
		$Global:PsMoviDesk_Storage.DEFAULT_SESSION = $Session;
	}
	
}

Function Get-DefaultMovideskSession {
	[CmdLetBinding()]
	param()
	
	if(@($Global:PsMoviDesk_Storage.SESSIONS).count -eq 1){
		$def =  @($Global:PsMoviDesk_Storage.SESSIONS)[0];
	} else {
		$def = $Global:PsMoviDesk_Storage.DEFAULT_SESSION
	}
	
	if(!$def){
		throw "NO_DEFAULT_Movidesk_SESSION";
	}
	
	return $def;
	
}

Function Clear-Movidesk {
	[CmdLetBinding()]
	param()
	
	$Global:PsMoviDesk_Storage = @{};
}

<#
	.SYNOPSIS
		Create a new session information
		
	.DESCRIPTION
		Creates a new session with otrs server and returns a object containing session information.
		The object returned is same as documented on otrs API.
		If errors occurs, exceptions is throws.
#>
Function New-MovideskSession {
	[CmdLetBinding()]
	param(
		 $Url
		,$Token
	)
	$AllSessions 		= $Global:PsMoviDesk_Storage.SESSIONS;
	$ExistentSession 	= Get-MovideskSession -Url $url -token $token;
	
	if($ExistentSession){
		throw "SESSION_ALREADY_EXIST";
	}
	
	$SessionId = BuildSessionId -url $Url -token $Token;
	
	$SessionO = New-Object PsObject -Prop @{
								id 		= $SessionId
								token	= $token
								url		= $url
							}
	
	if($AllSessions.count -eq 1){
		$Global:PsMoviDesk_Storage.DEFAULT_SESSION = $SessionO;
	}
	
	$AllSessions[$SessionId] += $SessionO;

	return $SessionO;
}

<#
	.SYNOPSIS
		Get all sessions
		
	.DESCRIPTION
		Get all sessions
#>
Function Get-MovideskSession {
	[CmdLetBinding()]
	param(
		$Token
		,$Url
	)
	$AllSessions = $Global:PsMoviDesk_Storage.SESSIONS;
	
	if(!$Token -and !$Url){
		return $AllSessions.Values;
	} elseif ($Token -and $Url) {
		$SessionId = BuildSessionId -url $Url -token $Token;
		return $AllSessions[$SessionID];
	} else {
		return $AllSessions.Values | ? { 
					($_.token -eq $Token -or !$token)
					-and
					($_.url -eq $Url -or !$Url)
			}
	}
}

<#
	.SYNOPSIS
		Get default sessions
		
	.DESCRIPTION
		Get default sessions
#>
Function Get-MovideskDefaultSession {
	[CmdLetBinding()]
	param(
		[parameter(ValueFromPipeline)]
		$Session
	)
	
	return $Global:PsMoviDesk_Storage.DEFAULT_SESSION;
}

<#
	.SYNOPSIS
		Get the default session
		
	.DESCRIPTION
		Default session as session set by Set-DefaultMovideskSession.
		The first session, is also set to default!
#>
Function Set-MovideskDefaultSession {
	[CmdLetBinding()]
	param(
		[parameter(ValueFromPipeline)]
		$Session
	)
	$Global:PsMoviDesk_Storage.DEFAULT_SESSION = $Session;
}

function BuildSessionId {
	param($url,$token)
	
	return  $Url,$token -Join "|";
}
	
