local M = {
	_AUTHOR = 'Rain Gloom',
	_DESCRIPTION = 'Syntax-aware lambda in pure Lua',
	_LICENSE = 'MIT',
}
setmetatable( M, M )
--TODO: handle garbage collection
M.functionReferenceCount = {}
M.upnameReferenceCount = {}
M.nameToFunctionMaps = {}--key: lambda


local checkedFunctions = {}
function M.functionCallHook( func )
	--only need to run this once per function
	if checkedFunctions[ func ] then return end
	for lambda, map in pairs( M.nameToFunctionMaps ) do
		for upname, _, upindex in M.upvalues( func ) do
			if map[ upname ] == func then
				local _, lambdaUpvalue, lambdaUpindex = M.findUpvalue( upname )
				debug.setupvalue( func, upindex, lambdaUpvalue )--apply latent assignment
				debug.upvaluejoin( lambda, lambdaUpindex, func, upindex )--lambda's upvalue now points to func's
			end
		end
	end
	checkedFunctions[ func ] = true
end


function M:__call( ... )
	return self.lambda( ... )
end


function M.upvalues( f )
	return coroutine.wrap(function()
		local i = 1
		while true do
			local k, v = debug.getupvalue( f, i )
			if k then
				coroutine.yield( k, v, i )
			else
				return
			end
			i = i + 1
		end
	end)
end


function M.locals( f, co )
	co = co or coroutine.running()
	return coroutine.wrap(function()
		require('mobdebug').on()
		local i = 1
		while true do
			local k, v = debug.getlocal( co, f, i )
			if k then
				coroutine.yield( k, v, i )
			else
				return
			end
			i = i + 1
		end
	end)
end


function M.activeFunctions( offset, what, co )
	offset = offset or 0
	co = co or coroutine.running()
	return coroutine.wrap( function()
		local i = 1 + offset
		while true do
			local r = debug.getinfo( co, i, what )
			if r then
				coroutine.yield( i, r )
			else
				return
			end
			i = i + 1
		end
	end)
end


function M.parentFunctions( offset )
	local co = coroutine.running()
	return coroutine.wrap(function()
		offset = offset or 0
		local funcI = 1 + offset
		local lastFuncInfo
		while true do
			--we need linedefined and activelines
			local funcInfo = debug.getinfo( co, funcI, 'S' )--mm, funky, also, this is the current function
			--no more functions
			if not funcInfo then return end
			--first iteration, lastFuncInfo is not yet initialized
			if not lastFuncInfo then
				coroutine.yield( funcI )
			else
				if
					(funcInfo.source ~= lastFuncInfo.source)--different file
					or (not (funcInfo.what == 'Lua' or funcInfo.what == 'main'))--not Lua or top level function of a file
					or (not (funcInfo.what == 'main' or funcInfo.linedefined <= lastFuncInfo.linedefined and lastFuncInfo.lastlinedefined <= funcInfo.lastlinedefined))--check if definitions line up
					--main wraps as it is the entire source file
				then
					return
				else
					coroutine.yield( funcI )
				end
			end
			funcI = funcI + 1
			lastFuncInfo = funcInfo
		end
	end)
end


function M.functionsWithUpvalueCandidates( offset, co )
	co = co or coroutine.running()
	local functions = {}
	offset = offset or 1
	for functionIndex in M.parentFunctions( offset, co ) do
		for localName in M.locals( functionIndex, co ) do
			--check if it is a valid local and not eg.: a temporary
			if localName:match'^[%a_][%w_]*$' then
				local previousIndex = functions[ localName ]
				--higher index -> farther down in call stack -> locals are shadowed by closer functions
				if not previousIndex or previousIndex > functionIndex then
					functions[ localName ] = functionIndex
				end
			end
		end
	end
	for k, i in pairs( functions ) do
		functions[ k ] = debug.getinfo( i, 'f' ).func
	end
	return functions
end


function M.searchForUpvalueInLocals( funcs, name )
	local f = funcs[ name ]
	if f then
		for funci, inf in M.activeFunctions( 3 ) do
			if inf.func == f then
				for k, _, loci in M.locals( funci ) do
					if k == name then
						return funci, loci
					end
				end
			end
		end
	end
end


function M.envMetatable:__index()
end


function M.envMetatable:__newindex()
end


function M.findUpvalue( func, name, co )
	co = co or coroutine.running()
	for k in M.upvalues( func, co ) do
		if k == name then
			return func, name, co
		end
	end
end



function M.lambda( source )
	local nameToFunctionMap = M.functionsWithUpvalueCandidates()--TODO: offest might be needed
	local functionSet = {}
	local upvalues = {}
	for k, v in pairs( nameToFunctionMap ) do
		M.upnameReferenceCount[ k ] = (M.upnameReferenceCount[ k ] or 0) + 1
		M.functionReferenceCount[ v ] = (M.functionReferenceCount[ v ] or 0) + 1
		functionSet[ v ] = true
	end
	for functionIndex, functionInfo in M.activeFunctions( 3, 'f' ) do
		if functionSet[ functionInfo.func ] then
			for localName, _, localIndex in M.locals( functionIndex ) do
				if nameToFunctionMap[ localName ] then
					upvalues[ localName ] = debug.getlocal( functionIndex, localIndex )
				end
			end
		end
	end
	local upvalueInitializerPrefix, upvaluesInOrder, i = {}, {}, 1
	for name, value in pairs( upvalues ) do
		upvalueInitializerPrefix[ i ], upvaluesInOrder[ i ], i = name, value, i + 1
	end
	upvaluesInOrder.n = i - 1
	--add the upvalue candidates to the source
	upvalueInitializerPrefix = table.concat( upvalueInitializerPrefix, ',' )
	source = string.format( 'local %s = ...; return %s', upvalueInitializerPrefix, source )
	local lambda = load( source )( (unpack or table.unpack)( upvaluesInOrder, 1, upvaluesInOrder.n ))
	M.nameToFunctionMaps[ lambda ] = nameToFunctionMap
	return lambda
end


return M
