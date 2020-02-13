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
					
				CUSTOM_FIELDS_ALIAS = @{
						
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
	
	Function Movidesk_Datetime2StringTime {
		param($Datetime)
		
		return $Datetime.toString("yyyy-MM-ddT00:00:00\z")
	}
	
	<#
		Build a odata that filters multiple values
		Value can be a single or aray value!
	
			If value is a simple string.
			In any of cases above, the function will generate following:
				
				FieldName eq 'VALUE'
				
			Value can contains special string.
			If value is ^VALUE this will be turned into startsiwth(FieldName, 'VALUE')
			VALUE$ this will be turned into endswith(FieldName, 'VALUE')
			You can combine both, for example ^VALUE$ and it will generated "startswith(...) and endswith(...)"
			
		If you specify LambdaFieldName, it will turn expression into
		
			FieldName(f: f/LambdaFieldName OP)
			
		OP depends on value, following rule above!
		
		For array value, it will repeat rules above for each array element.
		By default, it will generate a OR operation between fields.
		But, you can control this for each element using a '&' in VALUE.
		If it finds a '&' then it generate a AND for that array element!
		
		Examples:
		
			-FieldName c -Value A 
				c eq 'A'
				
			-FieldName f1 -Value A  -LambdaFieldName prop1/prop11
			
				f1(f: prop1/prop11 eq 'A' )
				
			-FieldName c -Value A,B 
				(c eq 'A') or (c eq 'B')
				
			-FieldName c -Value '^A','B$'
				startswith(c,'A') or endswith(c,'B')
				
			-FieldName c -Value '^A$','B'
				(startswith(c,'A') and endswith(c,'B')) or c eq 'B'
				
		
			-FieldName c -Value A,'&B','&C'
				(c eq 'A') and (c eq 'B') and (c eq 'C')
				
			-FieldName c/any -Value A,'&B','&C' -LambdaFieldName 'propA'
				c/any(f: f/propA c eq 'A') and c/any(f: f/propA eq 'B') and c/any(f: f/propA eq 'C')
				
			-FieldName c/any -Value A,'B','&C' -LambdaFieldName 'propA'
				c/any(c eq 'A') and c/any(c eq 'B') and c/any(c eq 'C')
				
			-FieldName c/all -Value '^A$','B' LambdaFieldName 'x/y'
				c/all(f: (startswith(f/x/y,'A') and endswith(f/x/y,'B'))) or c/all(f: f/x/y eq 'B' ) 
	#>
	Function Movidesk_BuildExpressionFilter {
		param(
			$FieldName
			,$Value
			
			,#If lambda, means we must build filter using $FiledName(f: expressions ) 
			 #Lambda field is name used in expressions (can contains /).
				$LambdaFieldName
		)
		
		$AllExpressions = @();
		
		$Value | %{
			#If first value is a "and", then will prefix join with AND boolean operator! Default is or!
			if($_[0] -eq '&'){
				$ItemOp = 'and'
			} else {
				$ItemOp = 'or'
			}
			
			$ItemValue = $_  -replace '^&','' -replace '^\\\&','&';
			
			#If a array field name was passed, then we will build with f/FieldName
			#f will be from the array lambda expression!
			if($LambdaFieldName){
				$ExprFieldName = "f/$LambdaFieldName"
			} else {
				$ExprFieldName = $FieldName;
			}
			
			#All expressions here!
			$FullExpr = @();
			
			#Check if starts with...
			$IsSW = $false;
			$IsEW = $false;
			
			#Check if is starts..
			if( $ItemValue[0] -eq '^' ){
				$IsSW = $true;
			}
			$ItemValue = $ItemValue  -replace '^\^','' -replace '^\\\^','^';
			
			#Check if is ends..
			if($ItemValue -match '[^\\]\$$'){
				$IsEW = $true;
				$ItemValue = $ItemValue  -replace  '([^\\])\$$','$1'
			} else {
				#Escapes \$..
				$ItemValue = $ItemValue  -replace '\\\$$','$';
			}
			
			
			if($IsSW){
				$FullExpr += "startswith($ExprFieldName,'$ItemValue')";
			}
			
			#Endwith function... (syntax: VALUE$, escape: VALUE\$)
			if($IsEW){
				$FullExpr += "endswith($ExprFieldName,'$ItemValue')";
			}
			
			#If not advanced expression, then just a simple equals operator!
			if(!$FullExpr){
				$FullExpr = "$ExprFieldName eq '$ItemValue'";
			}
			
			#If have something on expression list, add with boolean operator
			#We will join after...
			if($AllExpressions){
				$AllExpressions += " $ItemOp ";
			}
		
			#Build final expression.
			$Expr = $FullExpr -Join " and ";
			
			if($LambdaFieldName){
				$AllExpressions += "$FieldName(f: ($expr))"
			} else {
				$AllExpressions += "($expr)"
			}
			
			
		}
			
		return $AllExpressions -Join "";
	}
	
	#Build a custom field expression filter'
	Function Movidesk_BuildCustomFieldFilter {
		param($CustomFields, $CustomFieldName = 'customFieldValues')
		
		if($CustomFields){
			$CustomFieldsFilters = @();
			$CustomFields | %{
						$FieldAlias	 	= $_.name;
						$FieldID 		= $_.f;
						$RuleId 		= $_.r;
						
						
						if($FieldAlias){
							$AliasSlot = Get-MovideskCustomFieldAlias $FieldAlias -Expected
							$FieldID 		= $AliasSlot.customFieldId;
							$RuleId 		= $AliasSlot.customFieldRuleId;
						}
						
						
						$Value			= $_.value;
						$ValueStart		= $_.ValueStart;
						$ValueEnd		= $_.ValueEnd;
						$items			= $_.items;
						$ItemOp			= $_.ItemsOp;
						
						#Convert to datetime formats!
						if($Value -is [datetime]){
							$Value = Movidesk_Datetime2StringTime $Value;
						}
						
						if($ValueStart -is [datetime]){
							$ValueStart = Movidesk_Datetime2StringTime $ValueStart;
						}
						
						if($ValueEnd -is [datetime]){
							$ValueEnd = Movidesk_Datetime2StringTime $ValueEnd;
						}

						$FieldFilters = @(
							"cf/customFieldId eq $FieldID"
							"cf/customFieldRuleId eq $RuleId"
						)
						
						if($Value){
							#Build
							#
							#	( (cf/value eq Value1) or (repeat for Value2) or (repeat for Value3))
							#
							$ValueFilter = Movidesk_BuildExpressionFilter -FieldName "cf/value" -Value $Value
							$FieldFilters += "($ValueFilter)"
						}
						
						if($ValueStart){
							$FieldFilters +=  "(cf/value gt '$ValueStart')"
						}
						
						if($ValueEnd){
							$FieldFilters +=  "(cf/value le '$ValueEnd')"
						}
						
						#Build the items filter!
						#We ill build a expression joined by or:
						#
						#		(cf/items/ItemFunc(i: i/customFieldItem eq Value1) or (repeat for Value2) or (repeat for Value3))
						#						
						#
						if($items){
							$ItemFunc 		= $_.ItemsFunc;
							if(!$ItemFunc){ $ItemFunc = 'any' };
							
							$ItemsFilter = Movidesk_BuildExpressionFilter -FieldName "cf/items/$ItemFunc" -Value $items -LambdaFieldName customFieldItem
								
							$FieldFilters += "($ItemsFilter)"
						}

						#Generate filter between fields...
						$FieldFilters = $FieldFilters -Join " and ";
						$CustomFieldsFilters += "$CustomFieldName/any(cf: $FieldFilters)"
				}
				
			$CustomFieldsFilters = $CustomFieldsFilters -Join " $OpCustomFields ";
			return "($CustomFieldsFilters)"
		}

	}
	
	
	#add properties to a object based on custom field 
	#Person cache is a optionally cache of eprson to be used efficiently as a query of expand person items!
	#It is hashtable indexes by person id. Each key contains a object representing the person;
	#THe properties we need in this oject is id and businessName.
	#If you want show more than businessName original value, generated objects with them!
	Function Movidesk_MapProperty2CustomField {
		[CmdletBinding()]
		param($o, $CustomFieldMap, $PersonCache = $null, [switch]$Force, [switch]$GetPersonCache)
		
		if($GetPersonCache){
			$AllP = Get-MovideskPerson -select id,businessName -expand '';
			$pc = @{};
			$AllP | %{  $pc[$_.id] = $_ };
			return $Pc;
		}
		
		if($PersonCache -is [hashtable]){
			$LocalPersonCache = $PersonCache;
		} else {
			$LocalPersonCache = @{};
		}
		

		
		if($CustomFieldMap){
			$TargetObject = $o;
			
			
			@($CustomFieldMap) | %{
				if($_ -is [hashtable]){
					$PropName 		= $_.prop;
					$FieldAlias	 	= $_.name;
					$FieldId		= $_.f;
					$RuleId			= $_.r;
				} else {
					$PropName 		= [string]$_;
					$FieldAlias	 	= [string]$_;
				}

			
				if($FieldAlias){
					$AliasSlot 	= Get-MovideskCustomFieldAlias $FieldAlias -Expected
					$FieldID 	= $AliasSlot.customFieldId;
					$RuleId 	= $AliasSlot.customFieldRuleId;
				}
				
				if(!$PropName){
					throw "MOVIDESK_FIELDPROP_EMPTYPROP";
				}
				
				if($TargetObject.customFieldValues){
					$TheField = $TargetObject.customFieldValues | ? { $_.customFieldId -eq $FieldID -and $_.customFieldRuleId -eq $RuleId };
					
					if($TheField){
						
						#Get all data!
						
						$PropValue	 = @($TheField | %{
											if($_.Value){ $_.Value }
											if($_.items){ 
												$_.items | %{ 
													if($_.personId){
														if($LocalPersonCache.Contains($_.personId)){
															$ThePerson = $LocalPersonCache[$_.personId];
														} else {
															#Get from server...
															$ThePerson = Get-MovideskPerson -Id $_.personId -select id,businessName -expand '';
															$LocalPersonCache[$_.personId] = $ThePerson;
														}
														
														return $ThePerson.businessName;
													} 
													elseif ($_.fileName){
														return $_.fileName
													}
													else {
														return $_.customFieldItem 
													}	
												}
											}
									}|?{$_})
									
						if($PropValue.count -eq 1){
							$PropValue = $PropValue[0];
						}						
						
					} else {
						$PropValue = $null;
					}
					
				} else {
					$PropValue = $null
				}
				
				$TargetObject | Add-Member -Name $PropName -Type Noteproperty -Value $PropValue -Force:$ForceAdd;
			}
		}
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
			,[switch]$OnlyFilterCustom 
			
			,$top = $null
			
			,$tags = @()
			
			
			,#Custom field filter
				#Specify in format: @{ name= Alias|f = FiledId, r = ruleID; value = filtervalue; items = ItemsFilter  }
					$CustomFields = @()
			
			,#Logical operator to be used when multiple onditions in CustomFields
				[ValidateSet("or","and")]
				$OpCustomFields = "and"
				
			,#Map fields to properties!
				$FieldProperty	= $null
					
			
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
			expand		= 'createdBy,owner,clients,customFieldValues,customFieldValues($expand=items)'
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

		if($CustomFields){
			$CustomFields = Movidesk_BuildCustomFieldFilter $CustomFields;
			if($CustomFields){
				$AllFilter += $CustomFields;
			}
		}

		###gather all flters!
		if($FilterCustom){
			if($OnlyFilterCustom){
				$AllFilter = $FilterCustom;
			} else {
				$AllFilter += $FilterCustom;
			}
			
		}

		if($AllFilter){
			$Params['filter'] = $AllFilter -Join " and ";
		} else {
			if(!$Force){
				throw "You dont specify no filter. Use -Force to ack this.";
				return;
			}
		}
		
		
		$r = New-MovideskRequest @Params;
		
		if($RawResult){
			return $r;
		}
		
		$PersonCache = $null;
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
				
				if($FieldProperty){
					#Field property was passed build a person cache...
					if(!$PersonCache){
						$PersonCache = Movidesk_MapProperty2CustomField -GetPersonCache
					}
					Movidesk_MapProperty2CustomField $_ $FieldProperty -PersonCache $PersonCache
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
			,$expand = 'emails,customFieldValues,customFieldValues($expand=items)'
			,[string[]]$IncludeSelect = @()
			
			,#Custom field filter
				#Specify in format: @{ f = FiledId, r = ruleID; value = filtervalue; items = ItemsFilter  }
					$CustomFields = @()
			
			,#Logical operator to be used when multiple onditions in CustomFields
				[ValidateSet("or","and")]
				$OpCustomFields = "and"
				
			,#Map fields to properties!
				$FieldProperty	= $null
				
				
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
		
		$PROFILE_TYPES = @{
			1 	= 'Agente'
			2	= 'Cliente'
			3	= 'AgentClient'
		}
		
		
		
		if($IncludeSelect){
			$SelectList 	= @($select);
			$SelectList		+= @($IncludeSelect | ? {  $select -NotContains $_  })
			$Params['select'] = $SelectList
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
			$NameFilter = Movidesk_BuildExpressionFilter -FieldName 'businessName' -Value $Name;
			$AllFilter  += "($NameFilter)";
		}
		
		if($Email){
			$EmailFilter = Movidesk_BuildExpressionFilter -FieldName 'Emails/any' -Value $Email -LambdaFieldName 'email';
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
		
		
		if($CustomFields){
			$CustomFields = Movidesk_BuildCustomFieldFilter $CustomFields;
			if($CustomFields){
				$AllFilter += $CustomFields;
			}
		}

		

		
		if($AllFilter){
			$Params['filter'] = $AllFilter -Join " and ";
		}
		

			
		$r = New-MovideskRequest @Params;
		
		if($RawResult){
			return $r;
		}
		

		$PersonCache = $null;
		$r | %{
			if($_.personType){
				$_ | Add-Member -Type Noteproperty -Name personTypeDesc  -Value ($PERSON_TYPES[$_.personType])
			}
			
			if($_.emails){
				$defaultEmail = $_.emails | ? { $_.isDefault };
				$_ | Add-Member -Type Noteproperty -Name email -Value $defaultEmail.email;
			}
			
			if($_.profileType){
				$_ | Add-Member -Type Noteproperty -Name profileTypeDesc  -Value ($PROFILE_TYPES[$_.profileType])
			}

			if($FieldProperty){
				#Field property was passed build a person cache...
				if(!$PersonCache){
					$PersonCache = Movidesk_MapProperty2CustomField -GetPersonCache
				}
				Movidesk_MapProperty2CustomField $_ $FieldProperty -PersonCache $PersonCache
			}
		}	
		
		
		return $r;
	}
	
	<#
	Function Get-MovideskActivity {
		[CmdLetBinding()]
		param()
		
		$Params = @{
			DoRequest 	= $true
			endpoint	= 'activity'
			select		= 'id'
			#expand		= 'activityDto,teams'
		}

			
		$r = New-MovideskRequest @Params;
		
		return $r;
	}
	#>

	Function New-MovideskTicket {
		[CmdletBinding()]
		param(
			$TicketData
			
			#Some shortcuts! (This overwrte ticket data)
			,$createdBy	= $null
			,$team 		= $null
			,[string[]]$tags	= @()
			
			,$client		= $null
			
			#Will be the first action description!
			,$subject 		= $null
			,$description 	= $null
			
			#Custom fields (can be created with New-MovideskCustomField)
			,$CustomFields = $Null
			
			,[switch]$ReturnParams
		)
		
		$Params = @{
			DoRequest 	= $true
			data		= $null
			method		= 'POST'
			endpoint	= 'tickets'
		}
		
		$Errors = @()
		
		if(!$TicketData){
			$TicketData  = @{};
		}	
		
		#Priorities values...
		if($createdBy){
			$TicketData.createdBy = @{
				id = $createdBy.id
			}
		}
		
		if($team){
			$TicketData.ownerTeam = $team
		}


		
		if($client){
			[hashtable[]]$AllClients = @($client | %{
				@{id = $_.id};
			})
			
			$TicketData.clients = $AllClients;
		}
		
		if($subject){
			$TicketData.subject = $subject;
		}
		
		#Validate mandatory fields...
		if( !$TicketData.type ){
			$TicketData.type = 2;
		}
		
		#Validate mandatory fields...
		if( !$TicketData.subject ){
			$Errors += "Subject empty!"
		}

			
		#Validate mandatory fields...
		if( !$TicketData.createdBy ){
			$Errors += "Subject empty!"
		}
		
		#Validate mandatory fields...
		if( !$TicketData.clients ){
			$Errors += "Ticket client empty"
		}
		

				
		if($description){
			$NewAction = New-MovideskTicketAction -description $description -createdBy $createdBy -type $TicketData.type
			$OriginalActions = @($TicketData['actions']);
			$TicketData['actions'] = @($NewAction);
			
			if($OriginalActions){
				$TicketData['actions'] += $OriginalActions;
			}
			
		} else {
			$Errors += "Ticket description empty"
		}
		
		if($CustomFields){
			@($CustomFields) | %{
			
				if($_.name){
					$AliasSlot = Get-MovideskCustomFieldAlias $_.name -Expected;
					$_['customFieldId'] 		= $AliasSlot.customFieldId
					$_['customFieldRuleId'] 	= $AliasSlot.customFieldRuleId
					
					if($AliasSlot.RequiredTags){
						verbose "Adding tags to ticket creation due to required tags from custom field: $($_.name)";
						$tags += $AliasSlot.RequiredTags | ? {   $tags -NotContains $_  }
					}
					
				}
				
			}
			
			$ticketData.customFieldValues = @($CustomFields);
		}
		
		#Custom field validation!
		if($TicketData.customFieldValues){
			$i = 0;
			@($TicketData.customFieldValues)| %{
				$i++;
				if(!$_.customFieldId -or !$_.customFieldRuleId){
					$Errors += "field id or field rule id not set on custom field $i"
				}
				
				if(!$_.line){
					$_.line = 1;
				}
				
				if($_.value -is [datetime]){
					$_.value = Movidesk_Datetime2StringTime $_.value;
				}
				
				if($_.name){
					$_.Remove('name');
				}
			}
		}
		
		if($tags){
			$TicketData.tags = $tags
		}
		
		$Params['data'] = $TicketData;
		
		if($Errors){
			$AllErrors = $Errors -Join "`r`n";
			throw "MOVIDESK_NEWTICK_FAILED:`r`n$AllErrors"
		} elseif($ReturnParams) {
			return $Params;
		} else {
			New-MovideskRequest @Params;
		}
		
		
		
	}

	Function Update-MovideskTicket {
		[CmdletBinding()]
		param(
			 $ticket 
			 ,$NewAction
			 ,$subject 	
			 ,$ExcludeTags	= @()
			 ,$IncludeTags	= @()
			 ,[switch]$UseCurrentTicket 
			 ,$CustomFields	= @()
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
		
		if($UseCurrentTicket){
			if($Ticket -is [hashtable]){
				$NewTicketUpdate = $Ticket
				#$NewTicketUpdate.Remove('id');
			} else {
				throw "UPDATETICKET_USECURRENT_NOTHASHTABLE";
			}
		
			
		} else {
			$NewTicketUpdate = @{}
		}
		
		
		if($NewAction){
			$NewTicketUpdate['actions'] = [object[]]@($NewAction);
		}
		
		if($subject){
			$NewTicketUpdate['subject'] = $subject;
		}
		
		if($IncludeTags	 -or $ExcludeTags){
		
			#Get the tags from ticket!
			write-verbose "Getting ticket tags for include or exclude...";
			$CurrentTicket 	= Get-MovideskTicket -id $Ticket.id -select id,tags;
			$CurrentTags 	= $CurrentTicket.tags;
			
			if($IncludeTags){
				$CurrentTags += @($IncludeTags | ? { $CurrentTags -NotContains $_  });
			}
			
			
			$NewTicketUpdate['tags'] = [object[]]@($CurrentTags | ? { @($ExcludeTags) -NotContains $_ });
		}
		
		if($CustomFields){
			@($CustomFields) | %{
				if($_.name){
					$AliasSlot = Get-MovideskCustomFieldAlias $_.name -Expected;
					$_['customFieldId'] 		= $AliasSlot.customFieldId
					$_['customFieldRuleId'] 	= $AliasSlot.customFieldRuleId
					
					if($AliasSlot.RequiredTags){
						verbose "Adding tags to ticket update due to required tags from custom field: $($_.name)";
						$NewTicketUpdate['tags'] += [object[]]@($AliasSlot.RequiredTags | ? {   $NewTicketUpdate['tags'] -NotContains $_  })
					}
				
				}
			}
			

			
			$NewTicketUpdate['customFieldValues'] = @($CustomFields);
		}
		
		#Custom field validation!
		if($NewTicketUpdate.customFieldValues){
			$i = 0;
			@($NewTicketUpdate.customFieldValues)| %{
				$i++;
				if(!$_.customFieldId -or !$_.customFieldRuleId){
					$Errors += "field id or field rule id not set on custom field $i"
				}
				
				if(!$_.line){
					$_.line = 1;
				}
				
				if($_.value -is [datetime]){
					$_.value = Movidesk_Datetime2StringTime $_.value;
				}
				
				if($_.name){
					$_.Remove('name');
				}
			}
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

	#Creates a new custom field!
	Function New-MovideskCustomField {
		[CmdletBinding()]
		param(
			 $Alias
			,$FieldId
			,$RuleId
			,$Value
			,$HashTable
			,$Line 					= 1
			,[switch]$TimeValue		
		)
		
		if($Alias){
			$AliasSlot = Get-MovideskCustomFieldAlias $Alias -Expected;
			$FieldID = $AliasSlot.customFieldId;
			$RuleId = $AliasSlot.customFieldRuleId;
		}
		
		if(!$FieldId){
			throw "NEW_CUSTOMFIELD_INVALID_FIELDID"
		}
		
		if(!$RuleId){
			throw "NEW_CUSTOMFIELD_INVALID_RULEID"
		}
		
		$f = @{
			customFieldId 		= $FieldId
			customFieldRuleId	= $RuleId
			Line				= $Line
		}
		
		if($Value -is [object[]]){
			$items = @($Value | %{
					@{ customFieldItem = [string]$_ };
				})
			
			$f['items'] = [object[]]$items;
		} else {
			
			if($Value -is [datetime]){
				if($TimeValue){
					$Value = [datetime]$TimeValue.toString("1991-01-01 HH:mm:ss")
				}
				
				$Value = Movidesk_Datetime2StringTime $Value;
			}
			
			$f['value'] = $Value;
		}
		
		return $f;
		
	}

	#Creates a alias (conepts only to this module)
	#This alias is aname that other commands of this module can use to better reference custom fields!
	Function New-MovideskCustomFieldAlias {
		param(
			$AliasName
			,$FieldId 
			,$RuleID
			,[string[]]$RequiredTags = @()
			,[switch]$Force
		)
		
		if(!$AliasName){
			throw "INVALID_ALIAS_NAME"
		}
		
		if(!$FieldID){
			throw "INVALID_ALIAS_ID";
		}
		
		if(!$RuleID){
			throw "INVALID_RULEID";
		}
		
		
		#Get existent..
		$AliasSlot = $Global:PsMoviDesk_Storage.CUSTOM_FIELDS_ALIAS[$AliasName];
		
		if($AliasSlot){
			if(!$Force){
				throw "ALIAS_AREADY_EXISTS";
			}
			
			$AliasSlot.customFieldId	= $FieldID
			$AliasSlot.customFieldRuleId	= $RuleID
			
			if($RequiredTags){
				$AliasSlot['RequiredTags']	+= $RequiredTags | ?{ $AliasSlot['RequiredTags'] -NotContains $_ }
			}
			
		} else {
			$Global:PsMoviDesk_Storage.CUSTOM_FIELDS_ALIAS[$AliasName] = @{
						customFieldId 		= $FieldID
						customFieldRuleId	= $RuleID
						AliasName			= $AliasName
						RequiredTags		= $RequiredTags
				}
		}
		
		
		#
		
	}
	
	function Get-MovideskCustomFieldAlias {
		[CmdletBinding()]
		param($AliasName, [switch]$Expected)
		
		if($AliasName){
			$res = $Global:PsMoviDesk_Storage.CUSTOM_FIELDS_ALIAS[$AliasName];
			if(!$res -and $Expected){
				throw "CUSTOMFIELDALIAS_NOTFOUND: $AliasName";
			}
			return $res;
		} else {
			return @($Global:PsMoviDesk_Storage.CUSTOM_FIELDS_ALIAS.Values) | %{ new-Object PsObject -Prop $_ };
		}
		
		
	}

	function Remove-MovideskCustomFieldAlias {
		[CmdletBinding()]
		param($AliasName)
		
		$Global:PsMoviDesk_Storage.CUSTOM_FIELDS_ALIAS.Remove($AliasName);
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
		return $ExistentSession;
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
					($_.token -eq $Token -or !$token) -and ($_.url -eq $Url -or !$Url)
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
	
