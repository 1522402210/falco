local parser = require("parser")
local compiler = {}

function map(f, arr)
   local res = {}
   for i,v in ipairs(arr) do
      res[i] = f(v)
   end
   return res
end

function foldr(f, acc, arr)
   for i,v in pairs(arr) do
      acc = f(acc, v)
   end
   return acc
end

--[[

   Given a map of macro definitions, traverse AST and replace macro references
   with their definitions.

   The AST is changed in-place.

   The return value is a boolean which is true if any macro was
   substitued. This allows a caller to re-traverse until no more macros are
   found, a simple strategy for recursive resoltuions (e.g. when a macro
   definition uses another macro).

--]]
function expand_macros(ast, defs, changed)

   function copy(obj)
      if type(obj) ~= 'table' then return obj end
      local res = {}
      for k, v in pairs(obj) do res[copy(k)] = copy(v) end
      return res
   end

   if (ast.type == "Rule") then
      return expand_macros(ast.filter, defs, changed)
   elseif ast.type == "Filter" then
      if (ast.value.type == "Macro") then
         if (defs[ast.value.value] == nil) then
            error("Undefined macro '".. ast.value.value .. "' used in filter.")
         end
         ast.value = copy(defs[ast.value.value])
         changed = true
	 return changed
      end
      return expand_macros(ast.value, defs, changed)

   elseif ast.type == "BinaryBoolOp" then

      if (ast.left.type == "Macro") then
         if (defs[ast.left.value] == nil) then
            error("Undefined macro '".. ast.left.value .. "' used in filter.")
         end
         ast.left = copy(defs[ast.left.value])
         changed = true
      end

      if (ast.right.type == "Macro") then
         if (defs[ast.right.value] == nil) then
            error("Undefined macro ".. ast.right.value .. " used in filter.")
         end
         ast.right = copy(defs[ast.right.value])
         changed = true
      end

      local changed_left = expand_macros(ast.left, defs, false)
      local changed_right = expand_macros(ast.right, defs, false)
      return changed or changed_left or changed_right

   elseif ast.type == "UnaryBoolOp" then
      if (ast.argument.type == "Macro") then
         if (defs[ast.argument.value] == nil) then
            error("Undefined macro ".. ast.argument.value .. " used in filter.")
         end
         ast.argument = copy(defs[ast.argument.value])
         changed = true
      end
      return expand_macros(ast.argument, defs, changed)
   end
   return changed
end

function get_macros(ast, set)
   if (ast.type == "Macro") then
      set[ast.value] = true
      return set
   end

   if ast.type == "Filter" then
      return get_macros(ast.value, set)
   end

   if ast.type == "BinaryBoolOp" then
      local left = get_macros(ast.left, {})
      local right = get_macros(ast.right, {})

      for m, _ in pairs(left) do set[m] = true end
      for m, _ in pairs(right) do set[m] = true end

      return set
   end
   if ast.type == "UnaryBoolOp" then
      return get_macros(ast.argument, set)
   end
   return set
end

function check_for_ignored_syscalls_events(ast, filter_type, source)

   function check_syscall(val)
      if ignored_syscalls[val] then
	 error("Ignored syscall \""..val.."\" in "..filter_type..": "..source)
      end

   end

   function check_event(val)
      if ignored_events[val] then
	 error("Ignored event \""..val.."\" in "..filter_type..": "..source)
      end
   end

   function cb(node)
      if node.left.type == "FieldName" and
	 (node.left.value == "evt.type" or
	  node.left.value == "syscall.type") then

	    if node.operator == "in" then
	       for i, v in ipairs(node.right.elements) do
		  if v.type == "BareString" then
		     if node.left.value == "evt.type" then
			check_event(v.value)
		     else
			check_syscall(v.value)
		     end
		  end
	       end
	    else
	       if node.right.type == "BareString" then
		  if node.left.value == "evt.type" then
		     check_event(node.right.value)
		  else
		     check_syscall(node.right.value)
		  end
	       end
	    end
      end
   end

   parser.traverse_ast(ast, "BinaryRelOp", cb)
end

-- XXX/mstemm How to handle not?
-- XXX/mstemm How to handle specifying both directions in a condition? Currently just rejecting.
function get_evttypes(ast, source)

   local enter_evttypes = {}
   local exit_evttypes = {}
   local both_evttypes = {}
   local enter_direction = false
   local exit_direction = false

   function cb(node)
      if node.left.type == "FieldName" and node.left.value == "evt.type" then
	 if node.operator == "in" then
	    for i, v in ipairs(node.right.elements) do
	       if v.type == "BareString" then
		  if node.left.value == "evt.type" then
		     found_event = true

		     for id in string.gmatch(enter_events[v.value], "%S+") do
			enter_evttypes[id] = 1
			both_evttypes[id] = 1
		     end
		     for id in string.gmatch(exit_events[v.value], "%S+") do
			exit_evttypes[id] = 1
			both_evttypes[id] = 1
		     end
		  end
	       end
	    end
	 else
	    if node.right.type == "BareString" then
	       if node.left.value == "evt.type" then
		  found_event = true
		  for id in string.gmatch(enter_events[node.right.value], "%S+") do
		     enter_evttypes[id] = 1
		     both_evttypes[id] = 1
		  end
		  for id in string.gmatch(exit_events[node.right.value], "%S+") do
		     exit_evttypes[id] = 1
		     both_evttypes[id] = 1
		  end
	       end
	    end
	 end
      end
      if node.left.type == "FieldName" and node.left.value == "evt.dir" then
	 if node.right.value == ">" then
	    enter_direction = true
	 else
	    exit_direction = true
	 end
      end
   end

   parser.traverse_ast(ast, "BinaryRelOp", cb)

   if not found_event then
      error("Rule must contain an evt.type condition: "..source)
   end

   -- The event types to return is either the enter events, exit events, or both
   if ((enter_direction and exit_direction) or
      (not enter_direction and not exit_direction)) then
      return both_evttypes
   elseif enter_direction then
      return enter_evttypes
   else
      return exit_evttypes
   end
end

function compiler.compile_macro(line, list_defs)

   for name, items in pairs(list_defs) do
      line = string.gsub(line, name, table.concat(items, ", "))
   end

   local ast, error_msg = parser.parse_filter(line)

   if (error_msg) then
      print ("Compilation error: ", error_msg)
      error(error_msg)
   end

   -- Traverse the ast looking for events/syscalls in the ignored
   -- syscalls table. If any are found, return an error.
   check_for_ignored_syscalls_events(ast, 'macro', line)

   return ast
end

--[[
   Parses a single filter, then expands macros using passed-in table of definitions. Returns resulting AST.
--]]
function compiler.compile_filter(source, macro_defs, list_defs)

   for name, items in pairs(list_defs) do
      source = string.gsub(source, name, table.concat(items, ", "))
   end

   local ast, error_msg = parser.parse_filter(source)

   if (error_msg) then
      print ("Compilation error: ", error_msg)
      error(error_msg)
   end

   -- Traverse the ast looking for events/syscalls in the ignored
   -- syscalls table. If any are found, return an error.
   check_for_ignored_syscalls_events(ast, 'rule', source)

   if (ast.type == "Rule") then
      -- Line is a filter, so expand macro references
      repeat
	 expanded  = expand_macros(ast, macro_defs, false)
      until expanded == false

   else
      error("Unexpected top-level AST type: "..ast.type)
   end

   evttypes = get_evttypes(ast, source)

   return ast, evttypes
end


return compiler
