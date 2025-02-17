require("scene.lua");
require("utils.lua");

-- JSON DECODE FUNCTIONS

local escape_char_map = {
	[ "\\" ] = "\\\\",
	[ "\"" ] = "\\\"",
	[ "\b" ] = "\\b",
	[ "\f" ] = "\\f",
	[ "\n" ] = "\\n",
	[ "\r" ] = "\\r",
	[ "\t" ] = "\\t",
}

local escape_char_map_inv = { [ "\\/" ] = "/" }
for k, v in pairs(escape_char_map) do
	escape_char_map_inv[v] = k
end

local parse

local function create_set(...)
	local res = {}
	for i = 1, select("#", ...) do
	res[ select(i, ...) ] = true
	end
	return res
end

local space_chars	= create_set(" ", "\t", "\r", "\n")
local delim_chars	= create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals	= create_set("true", "false", "null")

local literal_map = {
  [ "true"  ] = true,
  [ "false" ] = false,
  [ "null"  ] = nil,
}

local function next_char(str, idx, set, negate)
  for i = idx, #str do
	if set[str:sub(i, i)] ~= negate then
	  return i
	end
  end
  return #str + 1
end

local function decode_error(str, idx, msg)
  local line_count = 1
  local col_count = 1
  for i = 1, idx - 1 do
	col_count = col_count + 1
	if str:sub(i, i) == "\n" then
	  line_count = line_count + 1
	  col_count = 1
	end
  end
  error( string.format("%s at line %d col %d", msg, line_count, col_count) )
end

local function codepoint_to_utf8(n)
  -- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
  local f = math.floor
  if n <= 0x7f then
	return string.char(n)
  elseif n <= 0x7ff then
	return string.char(f(n / 64) + 192, n % 64 + 128)
  elseif n <= 0xffff then
	return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
  elseif n <= 0x10ffff then
	return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
					   f(n % 4096 / 64) + 128, n % 64 + 128)
  end
  error( string.format("invalid unicode codepoint '%x'", n) )
end

local function parse_unicode_escape(s)
  local n1 = tonumber( s:sub(3, 6),  16 )
  local n2 = tonumber( s:sub(9, 12), 16 )
  -- Surrogate pair?
  if n2 then
	return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
  else
	return codepoint_to_utf8(n1)
  end
end

local function parse_string(str, i)
  local has_unicode_escape = false
  local has_surrogate_escape = false
  local has_escape = false
  local last
  for j = i + 1, #str do
	local x = str:byte(j)

	if x < 32 then
	  decode_error(str, j, "control character in string")
	end

	if last == 92 then -- "\\" (escape char)
	  if x == 117 then -- "u" (unicode escape sequence)
		local hex = str:sub(j + 1, j + 5)
		if not hex:find("%x%x%x%x") then
		  decode_error(str, j, "invalid unicode escape in string")
		end
		if hex:find("^[dD][89aAbB]") then
		  has_surrogate_escape = true
		else
		  has_unicode_escape = true
		end
	  else
		local c = string.char(x)
		if not escape_chars[c] then
		  decode_error(str, j, "invalid escape char '" .. c .. "' in string")
		end
		has_escape = true
	  end
	  last = nil

	elseif x == 34 then -- '"' (end of string)
	  local s = str:sub(i + 1, j - 1)
	  if has_surrogate_escape then
		s = s:gsub("\\u[dD][89aAbB]..\\u....", parse_unicode_escape)
	  end
	  if has_unicode_escape then
		s = s:gsub("\\u....", parse_unicode_escape)
	  end
	  if has_escape then
		s = s:gsub("\\.", escape_char_map_inv)
	  end
	  return s, j + 1

	else
	  last = x
	end
  end
  decode_error(str, i, "expected closing quote for string")
end

local function parse_number(str, i)
  local x = next_char(str, i, delim_chars)
  local s = str:sub(i, x - 1)
  local n = tonumber(s)
  if not n then
	decode_error(str, i, "invalid number '" .. s .. "'")
  end
  return n, x
end

local function parse_literal(str, i)
  local x = next_char(str, i, delim_chars)
  local word = str:sub(i, x - 1)
  if not literals[word] then
	decode_error(str, i, "invalid literal '" .. word .. "'")
  end
  return literal_map[word], x
end

local function parse_array(str, i)
  local res = {}
  local n = 1
  i = i + 1
  while 1 do
	local x
	i = next_char(str, i, space_chars, true)
	-- Empty / end of array?
	if str:sub(i, i) == "]" then
	  i = i + 1
	  break
	end
	-- Read token
	x, i = parse(str, i)
	res[n] = x
	n = n + 1
	-- Next token
	i = next_char(str, i, space_chars, true)
	local chr = str:sub(i, i)
	i = i + 1
	if chr == "]" then break end
	if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
  end
  return res, i
end

local function parse_object(str, i)
  local res = {}
  i = i + 1
  while 1 do
	local key, val
	i = next_char(str, i, space_chars, true)
	-- Empty / end of object?
	if str:sub(i, i) == "}" then
	  i = i + 1
	  break
	end
	-- Read key
	if str:sub(i, i) ~= '"' then
	  decode_error(str, i, "expected string for key")
	end
	key, i = parse(str, i)
	-- Read ':' delimiter
	i = next_char(str, i, space_chars, true)
	if str:sub(i, i) ~= ":" then
	  decode_error(str, i, "expected ':' after key")
	end
	i = next_char(str, i + 1, space_chars, true)
	-- Read value
	val, i = parse(str, i)
	-- Set
	res[key] = val
	-- Next token
	i = next_char(str, i, space_chars, true)
	local chr = str:sub(i, i)
	i = i + 1
	if chr == "}" then break end
	if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
  end
  return res, i
end

local char_func_map = {
  [ '"' ] = parse_string,
  [ "0" ] = parse_number,
  [ "1" ] = parse_number,
  [ "2" ] = parse_number,
  [ "3" ] = parse_number,
  [ "4" ] = parse_number,
  [ "5" ] = parse_number,
  [ "6" ] = parse_number,
  [ "7" ] = parse_number,
  [ "8" ] = parse_number,
  [ "9" ] = parse_number,
  [ "-" ] = parse_number,
  [ "t" ] = parse_literal,
  [ "f" ] = parse_literal,
  [ "n" ] = parse_literal,
  [ "[" ] = parse_array,
  [ "{" ] = parse_object,
}

parse = function(str, idx)
  local chr = str:sub(idx, idx)
  local f = char_func_map[chr]
  if f then
	return f(str, idx)
  end
  decode_error(str, idx, "unexpected character '" .. chr .. "'")
end

function decode(str)
  if type(str) ~= "string" then
	error("expected argument of type string, got " .. type(str))
  end
  local res, idx = parse(str, next_char(str, 1, space_chars, true))
  idx = next_char(str, idx, space_chars, true)
  if idx <= #str then
	decode_error(str, idx, "trailing garbage")
  end
  return res
end

SceneLib.registerPlugin(
	function (scene, attachment)
		scene.viewport:addToolButton("Gerador", 
		                             "Importar dd2vtt", 
									 "/icos/dd2vtt.png",
									 0,
									 {},
			function()
				if not scene.isGM then return end
				Dialogs.openFile("Selecione o arquivo", ".dd2vtt", false,
			        function(arquivos)
			            local arq = arquivos[1];

			            --showMessage(arq.name)
			            local str = arq.stream:readBinary("utf8")
			            local dg = decode(str)

			            local size = scene.grid.cellSize

			            scene.worldWidth = dg.resolution.map_size.x*size
			            scene.worldHeight = dg.resolution.map_size.y*size

			            local mapStream = Utils.newMemoryStream()
			            mapStream:writeBase64(dg.image)

			            --Save file locally
			            --Dialogs.saveFile("Salvar Imagem", mapStream, arq.name..".png", "image/png")

			            -- UPLOAD MAP TO FIREDRIVE
			            FireDrive.createDirectory("/uploads")

		              local date_table = os.date("*t")
		              local month = date_table.month
		              if month < 10 then
		              	month = "0"..month
		              end
				        	local subfolder = date_table.year.. "-" .. month

				        	FireDrive.createDirectory("/uploads/" .. subfolder)

				        	FireDrive.upload("/uploads/" .. subfolder .. "/" .. arq.name..".png", mapStream,
		                function(fditem)
											scene.bkgImageURL = fditem.url;	                		
		                end)

				        	local walls = false
				        	-- ADD WALLS
				        	for _,w in ipairs(dg.line_of_sight) do
				        		local polygon = {}
				        		local width = math.abs(w[1].x - w[2].x)
				        		local height = math.abs(w[1].y - w[2].y)
	
					      	  if width > height then
					      	  	polygon[1] = {x=(w[1].x)*size,y=(w[1].y-0.05)*size}
					      	  	polygon[2] = {x=(w[2].x)*size,y=(w[2].y-0.05)*size}
					      	  	polygon[3] = {x=(w[2].x)*size,y=(w[2].y+0.05)*size}
					      	  	polygon[4] = {x=(w[1].x)*size,y=(w[1].y+0.05)*size}
					      	  else
					      	  	polygon[1] = {x=(w[1].x-0.05)*size,y=(w[1].y)*size}
					      	  	polygon[2] = {x=(w[2].x-0.05)*size,y=(w[2].y)*size}
					      	  	polygon[3] = {x=(w[2].x+0.05)*size,y=(w[2].y)*size}
					      	  	polygon[4] = {x=(w[1].x+0.05)*size,y=(w[1].y)*size}
					      	  end
				        		scene.fogOfWar:addOpaqueArea(polygon)
				        		walls = true
				        	end

				        	--ADD DOORS
				        	for _,p in ipairs(dg.portals) do
				        		local w = p.bounds
				        		local polygon = {}
				        		local width = math.abs(w[1].x - w[2].x)
				        		local height = math.abs(w[1].y - w[2].y)
	
					      	  if width > height then
					      	  	polygon[1] = {x=(w[1].x)*size,y=(w[1].y-0.05)*size}
					      	  	polygon[2] = {x=(w[2].x)*size,y=(w[2].y-0.05)*size}
					      	  	polygon[3] = {x=(w[2].x)*size,y=(w[2].y+0.05)*size}
					      	  	polygon[4] = {x=(w[1].x)*size,y=(w[1].y+0.05)*size}
					      	  else
					      	  	polygon[1] = {x=(w[1].x-0.05)*size,y=(w[1].y)*size}
					      	  	polygon[2] = {x=(w[2].x-0.05)*size,y=(w[2].y)*size}
					      	  	polygon[3] = {x=(w[2].x+0.05)*size,y=(w[2].y)*size}
					      	  	polygon[4] = {x=(w[1].x+0.05)*size,y=(w[1].y)*size}
					      	  end
				        		scene.fogOfWar:addOpaqueArea(polygon)
				        		walls = true
				        	end
	
				        	-- ADD AREA TO EXPLORE
				        	if walls then
				        		local polygon = {}
				        		polygon[1] = {x=0,y=0}
				        		polygon[2] = {x=scene.worldWidth,y=0}
				        		polygon[3] = {x=scene.worldWidth,y=scene.worldHeight}
				        		polygon[4] = {x=0,y=scene.worldHeight}
	
										scene.fogOfWar.enabled = true
				        		scene.fogOfWar:setArea(polygon,"explorable")
				        	end

				        	-- ADD LIGHTS
				        	for _,p in ipairs(dg.lights) do
				        		local light = scene.items:addToken("background")
				        		light.x = (p.position.x-0.5) * size
				        		light.y = (p.position.y-0.5) * size
				        		light.lightIntenseRange = p.range*size
										light.lightAngle = 360
				        	end
			        end)
	
			end)
	end)