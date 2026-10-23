param(
    [string]$GamePath = ""
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$cecilDll = Join-Path $scriptDir 'Cecil\Mono.Cecil.dll'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Starmancer Atmosphere, Thermal & Phantom Leak Fix Patcher" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $cecilDll)) {
    Write-Error "Could not find Cecil dependencies at '$cecilDll'."
    exit 1
}

# 1. Find Game Directory
$resolvedGamePath = ""
$candidates = @()

if (-not [string]::IsNullOrWhiteSpace($GamePath)) {
    $candidates += $GamePath
}

# Check parent directory (if user unzipped inside Starmancer folder)
$candidates += (Join-Path $scriptDir '..')
$candidates += $scriptDir

# Common Steam library locations
$candidates += 'D:\SteamLibrary\steamapps\common\Starmancer'
$candidates += 'C:\Program Files (x86)\Steam\steamapps\common\Starmancer'
$candidates += 'C:\SteamLibrary\steamapps\common\Starmancer'
$candidates += 'E:\SteamLibrary\steamapps\common\Starmancer'
$candidates += 'F:\SteamLibrary\steamapps\common\Starmancer'
$candidates += 'S:\SteamLibrary\steamapps\common\Starmancer'

# Steam registry path detection
try {
    $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steamPath) {
        $candidates += (Join-Path $steamPath 'steamapps\common\Starmancer')
    }
} catch {}

foreach ($cand in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path $cand)) {
        $testTarget = Join-Path $cand 'Starmancer_Data\Managed\StarmancerMod.dll'
        if (Test-Path $testTarget) {
            $resolvedGamePath = (Resolve-Path $cand).Path
            break
        }
    }
}

while ([string]::IsNullOrWhiteSpace($resolvedGamePath) -or (-not (Test-Path (Join-Path $resolvedGamePath 'Starmancer_Data\Managed\StarmancerMod.dll')))) {
    Write-Host "Could not automatically detect Starmancer installation." -ForegroundColor Yellow
    $userInput = Read-Host "Please enter your Starmancer game folder (e.g. C:\SteamLibrary\steamapps\common\Starmancer)"
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        Write-Error "No path provided. Aborting installation."
        exit 1
    }
    $resolvedGamePath = $userInput.Trim('"', "'")
}

Write-Host "Target Starmancer Path: $resolvedGamePath" -ForegroundColor Green

$managedDir = Join-Path $resolvedGamePath 'Starmancer_Data\Managed'
$targetDll = Join-Path $managedDir 'StarmancerMod.dll'
$backupDll = Join-Path $managedDir 'StarmancerMod.dll.orig'

# 2. Backup vanilla file
if (-not (Test-Path $backupDll)) {
    Write-Host "Creating backup of original assembly: $backupDll" -ForegroundColor Yellow
    Copy-Item $targetDll $backupDll -Force
} else {
    Write-Host "Using existing vanilla backup: $backupDll" -ForegroundColor DarkGray
}

# 3. Apply Cecil Patches
Write-Host "Applying bytecode modifications via Mono.Cecil..." -ForegroundColor Cyan

Add-Type -Path $cecilDll

$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($managedDir)

$readerParams = New-Object Mono.Cecil.ReaderParameters
$readerParams.ReadWrite = $false
$readerParams.AssemblyResolver = $resolver

$asm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($backupDll, $readerParams)
$mainMod = $asm.MainModule

$singleTypeRef = $mainMod.TypeSystem.Single
$singleDef = $singleTypeRef.Resolve()
$isNaNMethodDef = $singleDef.Methods | Where-Object { $_.Name -eq 'IsNaN' -and $_.Parameters.Count -eq 1 }
$isInfMethodDef = $singleDef.Methods | Where-Object { $_.Name -eq 'IsInfinity' -and $_.Parameters.Count -eq 1 }

$isNaNRef = $mainMod.ImportReference($isNaNMethodDef)
$isInfRef = $mainMod.ImportReference($isInfMethodDef)

# --- PATCH 1: AtmosphereFlowDaemonComponent.CalculateAverages ---
# Fix: Prevent 0/0 = NaN when num2 == 0 (unpressurized rooms)
$daemonType = $mainMod.GetType('World.Atmosphere.Flow.AtmosphereFlowDaemonComponent')
$calcAvgMethod = $daemonType.Methods | Where-Object { $_.Name -eq 'CalculateAverages' }
$il = $calcAvgMethod.Body.GetILProcessor()

$divInstr = $null
foreach ($inst in $calcAvgMethod.Body.Instructions) {
    if ($inst.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Div) { $divInstr = $inst; break }
}
$convR8 = $divInstr.Previous
$ldloc1 = $convR8.Previous
$ldloc0 = $ldloc1.Previous
$ldargTempAvg = $ldloc0.Previous
$convR4 = $divInstr.Next
$stindR4 = $convR4.Next
$targetAfterStind = $stindR4.Next

$ilZeroPress = $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_S, $ldargTempAvg.Operand)
$set21 = $il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [single]21.0)
$store21 = $il.Create([Mono.Cecil.Cil.OpCodes]::Stind_R4)

$ilBranchZero = $il.Create([Mono.Cecil.Cil.OpCodes]::Ble_S, $ilZeroPress)
$ilBranchEnd = $il.Create([Mono.Cecil.Cil.OpCodes]::Br_S, $targetAfterStind)

$il.InsertBefore($ldargTempAvg, $il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_1))
$il.InsertBefore($ldargTempAvg, $il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$il.InsertBefore($ldargTempAvg, $ilBranchZero)

$il.InsertAfter($stindR4, $ilBranchEnd)
$il.InsertAfter($ilBranchEnd, $ilZeroPress)
$il.InsertAfter($ilZeroPress, $set21)
$il.InsertAfter($set21, $store21)
Write-Host "  [1/4] Patched CalculateAverages (0/0 division protection)" -ForegroundColor Green

# --- PATCH 2: PeriodicTemperatureExchangerComponent.TransferHeat ---
# Fix: Abort heat transfer immediately if either room is NaN or Infinity
$ventType = $mainMod.GetType('World.Atmosphere.Vent.PeriodicTemperatureExchangerComponent')
$transferHeatMethod = $ventType.Methods | Where-Object { $_.Name -eq 'TransferHeat' -and $_.Parameters.Count -eq 2 }
$ilVent = $transferHeatMethod.Body.GetILProcessor()

$stloc1 = $null
foreach ($inst in $transferHeatMethod.Body.Instructions) {
    if ($inst.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Stloc_1) { $stloc1 = $inst; break }
}
$retInstr = $transferHeatMethod.Body.Instructions[$transferHeatMethod.Body.Instructions.Count - 1]

$insPt = $stloc1
$guardInstructions = @(
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Call, $isNaNRef),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $retInstr),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_1),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Call, $isNaNRef),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $retInstr),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Call, $isInfRef),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $retInstr),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_1),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Call, $isInfRef),
    $ilVent.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $retInstr)
)
foreach ($g in $guardInstructions) {
    $ilVent.InsertAfter($insPt, $g)
    $insPt = $g
}
Write-Host "  [2/4] Patched TransferHeat (aborts -273C cascading drain)" -ForegroundColor Green

# --- PATCH 3: AtmosphereUnit.MoveToAverage ---
# Fix: Sanitize incoming average & auto-heal corrupted tiles in existing save files
$unitType = $mainMod.GetType('Starmancer.Agent.Components.Atmosphere.AtmosphereUnit')
$moveToAvgMethod = $unitType.Methods | Where-Object { $_.Name -eq 'MoveToAverage' }
$ilUnit = $moveToAvgMethod.Body.GetILProcessor()
$firstInstr = $moveToAvgMethod.Body.Instructions[0]

$tempField = $unitType.Fields | Where-Object { $_.Name -eq 'temperature_' }
$tempValueField = $tempField.FieldType.Resolve().Fields | Where-Object { $_.Name -eq 'temperature' }
$tempFieldRef = $mainMod.ImportReference($tempField)
$tempValFieldRef = $mainMod.ImportReference($tempValueField)

$setArg21 = $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [single]21.0)
$stArg2 = $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Starg_S, $moveToAvgMethod.Parameters[1])
$checkFloor = $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$healFloor = $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)

$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Call, $isNaNRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $setArg21))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Call, $isInfRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $checkFloor))

$ilUnit.InsertBefore($firstInstr, $setArg21)
$ilUnit.InsertBefore($firstInstr, $stArg2)

$ilUnit.InsertBefore($firstInstr, $checkFloor)
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $tempFieldRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $tempValFieldRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Call, $isNaNRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $healFloor))

$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $tempFieldRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $tempValFieldRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [single]-273.15))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Blt_S, $healFloor))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Br_S, $firstInstr))

$ilUnit.InsertBefore($firstInstr, $healFloor)
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $tempFieldRef))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [single]21.0))
$ilUnit.InsertBefore($firstInstr, $ilUnit.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $tempValFieldRef))
Write-Host "  [3/4] Patched MoveToAverage (auto-heals corrupt tiles & saves)" -ForegroundColor Green

# --- PATCH 4: AtmosphereLeakToSpaceComponent ---
# Fix: Periodic 10-leak counter triggers room adjacency refresh to eliminate phantom leaks
$leakType = $mainMod.GetType('World.Atmosphere.AtmosphereLeakToSpaceComponent')

$leakField = $leakType.Fields | Where-Object { $_.Name -eq 'leakCounter_' }
if (-not $leakField) {
    $leakField = New-Object Mono.Cecil.FieldDefinition('leakCounter_', [Mono.Cecil.FieldAttributes]::Private, $mainMod.TypeSystem.Int32)
    $leakType.Fields.Add($leakField)
}

$refreshMethod = $leakType.Methods | Where-Object { $_.Name -eq 'RefreshRoomAdjacency' }
if ($refreshMethod) { $leakType.Methods.Remove($refreshMethod) }

$agentType = $mainMod.GetType('Starmancer.Agent.Components.GameObjectAgent')
$agentRefType = $mainMod.GetType('Starmancer.Agent.Components.GameObjectAgentNonPrefabReference')
$roomParamType = $mainMod.GetType('Starmancer.Agent.Components.Room.OnQueryRoomParameter')
$eventNameType = $mainMod.GetType('Starmancer.Agent.Components.EventName')
$eventParamType = $mainMod.GetType('Starmancer.Agent.Components.AgentEventParameter')
$agentCompType = $mainMod.GetType('Starmancer.Agent.Components.AgentComponent')

$methodAttrs = [Mono.Cecil.MethodAttributes]([Mono.Cecil.MethodAttributes]::Private.value__ -bor [Mono.Cecil.MethodAttributes]::HideBySig.value__)
$refreshMethod = New-Object Mono.Cecil.MethodDefinition('RefreshRoomAdjacency', $methodAttrs, $mainMod.TypeSystem.Void)
$refreshMethod.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition('room', [Mono.Cecil.ParameterAttributes]::None, $agentType)))
$leakType.Methods.Add($refreshMethod)

$ilRefresh = $refreshMethod.Body.GetILProcessor()
$refreshMethod.Body.InitLocals = $true

$listOfObjType = $mainMod.GetType('Starmancer.Engine.ListOfObjects`1')
$genericListOfAgents = New-Object Mono.Cecil.GenericInstanceType($listOfObjType)
$genericListOfAgents.GenericArguments.Add($agentRefType)

$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($genericListOfAgents)))
$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($mainMod.TypeSystem.Int32)))
$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($agentRefType)))
$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($mainMod.TypeSystem.Int32)))

$roomTypeField = $leakType.Fields | Where-Object { $_.Name -eq 'roomType' }
$queryAgentsMethod = $roomParamType.Methods | Where-Object { $_.Name -eq 'Query_allAgentsInRoom_DoNotCache' }

$isLeakValid = $leakType.Methods | Where-Object { $_.Name -eq 'IsLeakValid' }
$getCountMethodRef = ($isLeakValid.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Callvirt }).Operand
$listGenericType = $getCountMethodRef.DeclaringType

$getItemMethodRef = New-Object Mono.Cecil.MethodReference('get_Item', $agentRefType, $listGenericType)
$getItemMethodRef.HasThis = $true
$getItemMethodRef.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($mainMod.TypeSystem.Int32)))

$agentRefField = $agentRefType.Fields | Where-Object { $_.Name -eq 'agentReference' }
$onRefreshEventField = $eventNameType.Fields | Where-Object { $_.Name -eq 'OnRefreshAdjacentObjects' }
$eventImplicit = $eventNameType.Methods | Where-Object { $_.Name -eq 'op_Implicit' -and $_.ReturnType.FullName -eq 'System.String' }
$getBaseParamMethod = $eventParamType.Methods | Where-Object { $_.Name -eq 'GetBase' -and $_.Parameters.Count -eq 0 }

$callEventDef = $agentType.Methods | Where-Object { $_.Name -eq 'CallEvent_ReturnToPool' -and $_.GenericParameters.Count -eq 1 -and $_.Parameters.Count -eq 2 }
$genCallEvent = New-Object Mono.Cecil.GenericInstanceMethod($callEventDef)
$genCallEvent.GenericArguments.Add($eventParamType)

$agentField = $agentCompType.Fields | Where-Object { $_.Name -eq 'agent_' }

$lblElseAgent = $ilRefresh.Create([Mono.Cecil.Cil.OpCodes]::Nop)
$lblRet = $ilRefresh.Create([Mono.Cecil.Cil.OpCodes]::Ret)

$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldarg_1)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblElseAgent)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldarg_1)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldfld, $roomTypeField)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Call, $queryAgentsMethod)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_0)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_0)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblRet)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_0)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Callvirt, $getCountMethodRef)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_3)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_1)

$lblLoopCheck = $ilRefresh.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_1)
$lblLoopBody = $ilRefresh.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0)

$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Br_S, $lblLoopCheck)
$ilRefresh.Append($lblLoopBody)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_1)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Callvirt, $getItemMethodRef)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_2)

$lblLoopInc = $ilRefresh.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_1)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_2)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblLoopInc)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_2)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldfld, $agentRefField)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblLoopInc)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_2)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldfld, $agentRefField)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldsfld, $onRefreshEventField)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Call, $eventImplicit)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Call, $getBaseParamMethod)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Callvirt, $genCallEvent)

$ilRefresh.Append($lblLoopInc)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Add)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_1)

$ilRefresh.Append($lblLoopCheck)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_3)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Blt_S, $lblLoopBody)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Br_S, $lblRet)

$ilRefresh.Append($lblElseAgent)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldfld, $agentField)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblRet)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldfld, $agentField)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldsfld, $onRefreshEventField)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Call, $eventImplicit)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Call, $getBaseParamMethod)
$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Callvirt, $genCallEvent)
$ilRefresh.Append($lblRet)

# Patch OnLeakAtmosphere
$leakMethod = $leakType.Methods | Where-Object { $_.Name -eq 'OnLeakAtmosphere' }
$ilLeak = $leakMethod.Body.GetILProcessor()
$brtrueInstr = ($leakMethod.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Brtrue_S })[0]
$targetInstr = $brtrueInstr.Operand

$lblSkipRefresh = $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Nop)
$counterInstructions = @(
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $leakField),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Add),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $leakField),

    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $leakField),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_S, [sbyte]10),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Blt_S, $lblSkipRefresh),

    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $leakField),

    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0),
    $ilLeak.Create([Mono.Cecil.Cil.OpCodes]::Call, $refreshMethod),

    $lblSkipRefresh
)
$brtrueInstr.Operand = $counterInstructions[0]
foreach ($ci in $counterInstructions) {
    $ilLeak.InsertBefore($targetInstr, $ci)
}

# Patch OnNotLeakingAtmosphere
$notLeakingMethod = $leakType.Methods | Where-Object { $_.Name -eq 'OnNotLeakingAtmosphere' }
$ilNotLeaking = $notLeakingMethod.Body.GetILProcessor()
$firstNotLeakInstr = $notLeakingMethod.Body.Instructions[0]

$ilNotLeaking.InsertBefore($firstNotLeakInstr, $ilNotLeaking.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$ilNotLeaking.InsertBefore($firstNotLeakInstr, $ilNotLeaking.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$ilNotLeaking.InsertBefore($firstNotLeakInstr, $ilNotLeaking.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $leakField))

Write-Host "  [4/4] Patched AtmosphereLeakToSpaceComponent (phantom leak 10-count adjacency recheck)" -ForegroundColor Green

# 4. Save and deploy
$writerParams = New-Object Mono.Cecil.WriterParameters
$writerParams.WriteSymbols = $false
$tempOut = Join-Path $managedDir 'StarmancerMod.dll.patched'
$asm.Write($tempOut, $writerParams)

Copy-Item $tempOut $targetDll -Force
Remove-Item $tempOut -Force

Write-Host ""
Write-Host "SUCCESS! Starmancer has been patched successfully." -ForegroundColor Green
Write-Host "Your station atmosphere is now fully protected." -ForegroundColor Green
Write-Host ""