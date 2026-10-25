param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\Starmancer'
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$managed = Join-Path $GameRoot 'Starmancer_Data\Managed'
$targetDll = Join-Path $managed 'StarmancerMod.dll'
$backupDll = Join-Path $managed 'StarmancerMod.dll.orig'
$cecilDll = Join-Path $scriptDir 'Cecil\Mono.Cecil.dll'

if (-not (Test-Path $targetDll)) {
    Write-Error "StarmancerMod.dll not found at '$targetDll'. Check your GameRoot path."
    exit 1
}

Write-Host "=== Reapplying Starmancer Thermal, NaN & Adjacency Fix ===" -ForegroundColor Cyan

# Backup the fresh reinstalled vanilla DLL if not already backed up
if (-not (Test-Path $backupDll)) {
    Copy-Item $targetDll $backupDll -Force
    Write-Host "Created backup of fresh vanilla DLL: $backupDll" -ForegroundColor Green
}

# Load Cecil from backup folder
Add-Type -Path $cecilDll

$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($managed)

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

# =========================================================================
# PATCH 1: AtmosphereFlowDaemonComponent.CalculateAverages (num2<=0 fallback)
# =========================================================================
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

# =========================================================================
# PATCH 2: PeriodicTemperatureExchangerComponent.TransferHeat (abort on NaN/Inf)
# =========================================================================
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

# =========================================================================
# PATCH 3: AtmosphereUnit.MoveToAverage (heal NaN / < -273.15C to 21C)
# =========================================================================
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

# =========================================================================
# PATCH 4: AtmosphereLeakToSpaceComponent (leak counter & room adjacency test every 10 leaks)
# =========================================================================
$leakType = $mainMod.GetType('World.Atmosphere.AtmosphereLeakToSpaceComponent')

# 1. Add leakCounter_ field
$leakField = $leakType.Fields | Where-Object { $_.Name -eq 'leakCounter_' }
if (-not $leakField) {
    $leakField = New-Object Mono.Cecil.FieldDefinition('leakCounter_', [Mono.Cecil.FieldAttributes]::Private, $mainMod.TypeSystem.Int32)
    $leakType.Fields.Add($leakField)
}

# 2. Build RefreshRoomAdjacency method
$refreshMethod = $leakType.Methods | Where-Object { $_.Name -eq 'RefreshRoomAdjacency' }
if ($refreshMethod) {
    $leakType.Methods.Remove($refreshMethod)
}

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

$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($genericListOfAgents))) # 0
$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($mainMod.TypeSystem.Int32))) # 1
$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($agentRefType))) # 2
$refreshMethod.Body.Variables.Add((New-Object Mono.Cecil.Cil.VariableDefinition($mainMod.TypeSystem.Int32))) # 3

$roomTypeField = $leakType.Fields | Where-Object { $_.Name -eq 'roomType' }
$queryAgentsMethod = $roomParamType.Methods | Where-Object { $_.Name -eq 'Query_allAgentsInRoom_DoNotCache' }

$blueprintType = $mainMod.GetType('World.AI.Pathfinding.GoToOrder.GoToFloorOrderBlueprintComponent')
$isThereObjectMethod = $blueprintType.Methods | Where-Object { $_.Name -eq 'IsThereAnObjectOnFloor' -and $_.Parameters[0].ParameterType.Name -like '*ListOfObjects*' }
$getCountMethodRef = ($isThereObjectMethod.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Callvirt -and $_.Operand.Name -eq 'get_Count' }).Operand
$getItemMethodRef = ($isThereObjectMethod.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Callvirt -and $_.Operand.Name -eq 'get_Item' }).Operand

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

$ilRefresh.Emit([Mono.Cecil.Cil.OpCodes]::Ldarg_1) # room
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

# 3. Patch OnLeakAtmosphere
$leakMethod = $leakType.Methods | Where-Object { $_.Name -eq 'OnLeakAtmosphere' }
$ilLeak = $leakMethod.Body.GetILProcessor()

$brtrueInstr = $null
foreach ($inst in $leakMethod.Body.Instructions) {
    if ($inst.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Brtrue_S) {
        $brtrueInstr = $inst
        break
    }
}
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

$firstCounterInstr = $counterInstructions[0]
$brtrueInstr.Operand = $firstCounterInstr

foreach ($ci in $counterInstructions) {
    $ilLeak.InsertBefore($targetInstr, $ci)
}

# 4. Patch OnNotLeakingAtmosphere: reset leakCounter_ = 0
$notLeakingMethod = $leakType.Methods | Where-Object { $_.Name -eq 'OnNotLeakingAtmosphere' }
$ilNotLeaking = $notLeakingMethod.Body.GetILProcessor()
$firstNotLeakInstr = $notLeakingMethod.Body.Instructions[0]

$ilNotLeaking.InsertBefore($firstNotLeakInstr, $ilNotLeaking.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$ilNotLeaking.InsertBefore($firstNotLeakInstr, $ilNotLeaking.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$ilNotLeaking.InsertBefore($firstNotLeakInstr, $ilNotLeaking.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $leakField))

# =========================================================================
# PATCH 5: GoToFloorOrderBlueprintComponent ESC / Cancel / Cleanup Fix
# =========================================================================
# Fixes colonist task-giving lockup where Escape key stops working.
# 1) In OnUserActionInvoked: Intercept CloseWindow and Cancel actions, absorb input, and call RemoveCursor().
# 2) In RemoveCursor: Unhide colonist window main area, deactivate hero mode if active,
#    unselect moused-over objects, unselect invalid floors, reset colonist_ = null,
#    trigger OnObjectNoLongerSelectedInUI, unregister global events, and call OnRemoved.
# 3) In OnRemoved: Unselect moused-over objects, unselect invalid floors, null out colonist_, and unregister global events.
# 4) In OnTick: Call RemoveCursor() instead of agent_.CallEvent(OnRemoved) when colonist is no longer valid.

$orderCompType = $mainMod.GetType('World.AI.Pathfinding.GoToOrder.GoToFloorOrderBlueprintComponent')
$removeCursorMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'RemoveCursor' }
$onUserActionMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'OnUserActionInvoked' }
$onTickMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'OnTick' }
$onRemovedMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'OnRemoved' }

$colonistField = $orderCompType.Fields | Where-Object { $_.Name -eq 'colonist_' }
$allMousedOverField = $orderCompType.Fields | Where-Object { $_.Name -eq 'allMousedOverObjects_' }
$allInvalidFloorsField = $orderCompType.Fields | Where-Object { $_.Name -eq 'allInvalidFloors_' }
$agentField = $orderCompType.BaseType.Resolve().Fields | Where-Object { $_.Name -eq 'agent_' }

$unselectMousedMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'UnselectAllMousedOverObjects' }
$unselectAllMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'UnselectAll' }
$unregisterGlobalMethod = $orderCompType.BaseType.Resolve().Methods | Where-Object { $_.Name -eq 'UnregisterAllGlobalEvents' }
$unregisterGlobalRef = $mainMod.ImportReference($unregisterGlobalMethod)

$userActionParamType = $mainMod.GetType('Starmancer.Agent.Components.Interface.Input.OnUserActionInvokedParameter')
if ($null -eq $userActionParamType) {
    $userActionParamType = $mainMod.GetType('Starmancer.UserAction.OnUserActionInvokedParameter')
}
$absorbMethod = $userActionParamType.Methods | Where-Object { $_.Name -eq 'AbsorbUserInput' }

$heroModeParamType = $mainMod.GetType('Starmancer.Agent.Components.Colonist.HeroMode.OnQueryHeroModeParameter')
$queryHeroActiveMethod = ($heroModeParamType.Methods | Where-Object { $_.Name -eq 'Query_isHeroModeActive' })[0]

$baseParamMethod = ($mainMod.GetType('Starmancer.Agent.Components.AgentEventParameter').Methods | Where-Object { $_.Name -eq 'GetBase' })[0]
$onRemovedParamMethod = ($mainMod.GetType('Starmancer.Agent.Components.World.Placeable.OnRemovedParameter').Methods | Where-Object { $_.Name -eq 'Get' -and $_.Parameters.Count -eq 0 })[0]

$agentType = $mainMod.GetType('Starmancer.Agent.Components.GameObjectAgent')
$callEventDef = ($agentType.Methods | Where-Object { $_.Name -eq 'CallEvent_ReturnToPool' -and $_.HasGenericParameters -and $_.Parameters.Count -eq 2 })[0]
$callEventBaseInst = New-Object Mono.Cecil.GenericInstanceMethod($callEventDef)
$callEventBaseInst.GenericArguments.Add($mainMod.GetType('Starmancer.Agent.Components.AgentEventParameter'))

$callEventRemovedInst = New-Object Mono.Cecil.GenericInstanceMethod($callEventDef)
$callEventRemovedInst.GenericArguments.Add($mainMod.GetType('Starmancer.Agent.Components.World.Placeable.OnRemovedParameter'))

$eventNameType = $mainMod.GetType('Starmancer.Agent.Components.EventName')
$opImplicitEventName = ($eventNameType.Methods | Where-Object { $_.Name -eq 'op_Implicit' })[0]
$fieldHeroDeactivated = $eventNameType.Fields | Where-Object { $_.Name -eq 'OnHeroModeDeactivated' }
$fieldOnRemoved = $eventNameType.Fields | Where-Object { $_.Name -eq 'OnRemoved' }

$selectionType = $mainMod.GetType('Starmancer.Component.Interface.Cursor.Selection.SelectionType')
$fieldSelectionDeletion = $selectionType.Fields | Where-Object { $_.Name -eq 'Deletion' }

$callerType = $mainMod.GetType('Starmancer.Agent.Components.GlobalEvent.GlobalEventCaller')
$callerInstField = $callerType.Fields | Where-Object { $_.Name -eq 'instance' }
$callGlobalEventDef = ($callerType.Methods | Where-Object { $_.Name -eq 'CallGlobalEvent_ReturnToPool' -and $_.Parameters[0].ParameterType.Name -eq 'GlobalEventName' })[0]
$callGlobalEventInst = New-Object Mono.Cecil.GenericInstanceMethod($callGlobalEventDef)
$callGlobalEventInst.GenericArguments.Add($mainMod.GetType('Starmancer.Agent.Components.AgentEventParameter'))

$genType = $mainMod.GetType('Starmancer.Agent.Components.GlobalEvent.GlobalEventName')
$fieldNoLongerSelected = $genType.Fields | Where-Object { $_.Name -eq 'OnObjectNoLongerSelectedInUI' }

# 1. Re-wire OnUserActionInvoked
$userActionType = $mainMod.GetType('Starmancer.Agent.Components.Interface.Input.UserActionType')
$fieldConfirmUp = $userActionType.Fields | Where-Object { $_.Name -eq 'UniversalConfirmUp' }
$fieldCloseWin = $userActionType.Fields | Where-Object { $_.Name -eq 'CloseWindow' }
$fieldCancel = $userActionType.Fields | Where-Object { $_.Name -eq 'Cancel' }

$dynamicEnumType = $mainMod.GetType('Starmancer.Engine.DynamicEnum')
$opEqualityDef = ($dynamicEnumType.Methods | Where-Object { $_.Name -eq 'op_Equality' })[0]

$paramType = $mainMod.GetType('Starmancer.Agent.Components.AgentEventParameter')
$tryCastDef = ($paramType.Methods | Where-Object { $_.Name -eq 'TryCastParameter' -and $_.HasGenericParameters })[0]
$tryCastInst = New-Object Mono.Cecil.GenericInstanceMethod($tryCastDef)
$tryCastInst.GenericArguments.Add($userActionParamType)

$userActionField = $userActionParamType.Fields | Where-Object { $_.Name -eq 'userAction' }
$createWinMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'CreateContextTargetWindow' }

$onUserActionMethod.Body.Instructions.Clear()
$onUserActionMethod.Body.Variables.Clear()
$var0 = New-Object Mono.Cecil.Cil.VariableDefinition($userActionParamType)
$onUserActionMethod.Body.Variables.Add($var0)

$ilUA = $onUserActionMethod.Body.GetILProcessor()
$lblRet = $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$lblCheckCancel = $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0)
$lblDoCancel = $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0)

$uaInstructions = @(
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $tryCastInst),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Stloc_0),

    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblRet),

    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $userActionField),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldConfirmUp),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Call, $opEqualityDef),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblCheckCancel),

    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Call, $createWinMethod),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Br_S, $lblRet),

    $lblCheckCancel,
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $userActionField),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldCloseWin),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Call, $opEqualityDef),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $lblDoCancel),

    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $userActionField),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldCancel),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Call, $opEqualityDef),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblRet),

    $lblDoCancel,
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $absorbMethod),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilUA.Create([Mono.Cecil.Cil.OpCodes]::Call, $removeCursorMethod),
    $lblRet
)

foreach ($inst in $uaInstructions) {
    $ilUA.Append($inst)
}

# 2. Re-wire RemoveCursor
$removeCursorMethod.Body.Instructions.Clear()
$removeCursorMethod.Body.Variables.Clear()
$ilRC = $removeCursorMethod.Body.GetILProcessor()

$lblSkipColonist = $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Nop)
$lblSkipAgentRemove = $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Nop)

$removeCursorInstructions = @(
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $colonistField),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblSkipColonist),

    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $colonistField),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $queryHeroActiveMethod),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblSkipColonist),

    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $colonistField),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldHeroDeactivated),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $opImplicitEventName),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $baseParamMethod),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $callEventBaseInst),

    $lblSkipColonist,
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $unselectMousedMethod),

    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $allInvalidFloorsField),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldSelectionDeletion),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $unselectAllMethod),

    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldnull),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $colonistField),

    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $callerInstField),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldNoLongerSelected),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $baseParamMethod),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $callGlobalEventInst),

    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $unregisterGlobalRef),

    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $agentField),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Dup),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblSkipAgentRemove),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldOnRemoved),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $opImplicitEventName),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Call, $onRemovedParamMethod),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $callEventRemovedInst),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ret),

    $lblSkipAgentRemove,
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Pop),
    $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ret)
)

foreach ($inst in $removeCursorInstructions) {
    $ilRC.Append($inst)
}

# 3. Re-wire OnRemoved
$onRemovedMethod.Body.Instructions.Clear()
$onRemovedMethod.Body.Variables.Clear()
$ilOR = $onRemovedMethod.Body.GetILProcessor()
$onRemovedInstructions = @(
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Call, $unselectMousedMethod),

    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $allInvalidFloorsField),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fieldSelectionDeletion),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Call, $unselectAllMethod),

    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldnull),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $colonistField),

    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Call, $unregisterGlobalRef),

    $ilOR.Create([Mono.Cecil.Cil.OpCodes]::Ret)
)
foreach ($inst in $onRemovedInstructions) {
    $ilOR.Append($inst)
}

# 4. Re-wire OnTick: if (!IsColonistValid(colonist_)) RemoveCursor(); else ParseAllFloors();
$isColonistValidMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'IsColonistValid' }
$parseFloorsMethod = $orderCompType.Methods | Where-Object { $_.Name -eq 'ParseAllFloors' }

$onTickMethod.Body.Instructions.Clear()
$onTickMethod.Body.Variables.Clear()
$ilTick = $onTickMethod.Body.GetILProcessor()
$lblRet = $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$lblParse = $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)

$tickInstructions = @(
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $colonistField),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblRet),

    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $colonistField),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Call, $isColonistValidMethod),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $lblParse),

    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Call, $removeCursorMethod),
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Br_S, $lblRet),

    $lblParse,
    $ilTick.Create([Mono.Cecil.Cil.OpCodes]::Call, $parseFloorsMethod),
    $lblRet
)

foreach ($inst in $tickInstructions) {
    $ilTick.Append($inst)
}

# Write patched assembly
$writerParams = New-Object Mono.Cecil.WriterParameters
$writerParams.WriteSymbols = $false
$tempOut = Join-Path $managed 'StarmancerMod.dll.patched'
$asm.Write($tempOut, $writerParams)

Copy-Item $tempOut $targetDll -Force
Copy-Item $tempOut (Join-Path $scriptDir 'StarmancerMod.dll.patched') -Force
Remove-Item $tempOut -Force

Write-Host "`nSUCCESS! All 5 patches applied (NaN heat drain + leak counter adjacency + order ESC cancel lockup fix)." -ForegroundColor Green
Write-Host "Vanilla backup saved to: $backupDll" -ForegroundColor DarkGray
