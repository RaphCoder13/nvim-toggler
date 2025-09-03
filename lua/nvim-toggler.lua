local log = {}
local banner = function(msg) return '[nvim-toggler] ' .. msg end
function log.warn(msg) vim.notify(banner(msg), vim.log.levels.WARN) end
function log.once(msg) vim.notify_once(banner(msg), vim.log.levels.WARN) end
function log.echo(msg) vim.api.nvim_echo({ { banner(msg), 'None' } }, false, {}) end

local defaults = {
  inverses = {
    ['true'] = 'false',
    ['yes'] = 'no',
    ['on'] = 'off',
    ['left'] = 'right',
    ['up'] = 'down',
    ['enable'] = 'disable',
    ['!='] = '==',
  },
  opts = {
    remove_default_keybinds = false,
    remove_default_inverses = false,
    autoselect_longest_match = false,
    smart_case_matching = true,
  },
}

---@param str string
---@param byte integer
---@return boolean
local function contains_byte(str, byte)
  for i = 1, #str do
    if str:byte(i) == byte then return true end
  end
  return false
end

---@param line string
---@param word string
---@param c_pos integer
---@return integer|nil, integer|nil
local function surround(line, word, c_pos)
  local w, W = 0, #word
  local l, L = math.max(c_pos - #word, 0), math.min(c_pos + #word, #line)
  while w < W and l < L do
    local _w, _l = word:byte(w + 1), line:byte(l + 1)
    w, l = _w == _l and w + 1 or word:byte(1) == _l and 1 or 0, l + 1
  end
  if w == W then return l - w + 1, l end
end

local case_type = {
  lower = {},
  upper = {},
  sentence = {},
  other = {},
}

---Returns the case_type enum
---@param line string
---@param lo integer
---@param hi integer
---@return table
local function check_casing(line, lo, hi)
  -- This will also be true for not letters
  local first_char = line:sub(lo, lo)
  local first_char_upper = first_char == first_char:upper()

  -- Handle single letter match
  if lo == hi then
    if first_char_upper then
      return case_type.upper
    else
      return case_type.lower
    end
  end

  local second_char = line:sub(lo + 1, lo + 1)
  local second_char_upper = second_char == second_char:upper()
  local current_type

  if first_char_upper then
    if second_char_upper then
      current_type = case_type.upper
    else
      current_type = case_type.sentence
    end
  elseif not second_char_upper then
    current_type = case_type.lower
  else
    return case_type.other
  end

  -- 2 letter match
  if hi - lo == 1 then return current_type end

  for i = lo + 2, hi do
    local char = line:sub(i, i)
    local is_upper = char == char:upper()
    if is_upper then
      if current_type ~= case_type.upper then return case_type.other end
    else
      if current_type == case_type.upper then return case_type.other end
    end
  end

  return current_type
end

local inv_tbl = { data = {}, hash = {} }

function inv_tbl:reset()
  self.hash, self.data = {}, {}
end

-- Adds unique key-value pairs to the inv_tbl.
--
-- If either the `key` or the `value` is found to be already in
-- `inv_tbl`, then the `key`-`value` pair will not be added.
function inv_tbl:add(tbl, verbose)
  for k, v in pairs(tbl or {}) do
    if not self.hash[k] and not self.hash[v] then
      self.data[k], self.data[v], self.hash[k], self.hash[v] = v, k, true, true
    elseif verbose then
      log.once('conflicts found in inverse config.')
    end
  end
end

local app = { inv_tbl = inv_tbl, inv_tbl_metadata = {}, opts = {} }

function app:load_opts(opts)
  opts = opts or {}
  for k in pairs(defaults.opts) do
    if type(opts[k]) == type(defaults.opts[k]) then
      self.opts[k] = opts[k]
    elseif opts[k] ~= nil then
      log.once('incorrect type found in config.')
    end
  end
end

function app.sub(line, result)
  local lo, hi, inverse = result.lo, result.hi, result.inverse
  line = table.concat({ line:sub(1, lo - 1), inverse, line:sub(hi + 1) }, '')
  return vim.api.nvim_set_current_line(line)
end

-- `word` is the string to be replaced
-- `inverse` is the string that will replace `word`
--
-- Toggle is executed on the first keyword found such that
--   1. `word` contains the character under the cursor.
--   2. current line contains `word`.
--   3. cursor is on that `word` in the current line.
function app:toggle()
  local line = vim.fn.getline('.')
  local cursor = vim.fn.col('.')
  local byte = line:byte(cursor)
  local results = {}

  -- Parcours toutes les paires mot/inverse
  for word, inverse in pairs(self.inv_tbl.data) do
    local metadata = self.inv_tbl_metadata[word]
    local use_smart_case = app.opts.smart_case_matching and metadata and metadata.has_only_lower_case

    if use_smart_case then
      local line_lower = line:lower()
      if contains_byte(word, line_lower:byte(cursor)) then
        local lo, hi = surround(line_lower, word, cursor)
        if lo and hi and lo <= cursor and cursor <= hi then
          local casing = check_casing(line, lo, hi)
          if casing ~= case_type.other then
            local formatted_inverse = inverse
            if casing == case_type.upper then
              formatted_inverse = inverse:upper()
            elseif casing == case_type.sentence then
              formatted_inverse = inverse:sub(1, 1):upper() .. inverse:sub(2)
            end
            table.insert(results, {
              lo = lo,
              hi = hi,
              inverse = formatted_inverse,
              word = word,
            })
          end
        end
      end
    else
      if contains_byte(word, byte) then
        local lo, hi = surround(line, word, cursor)
        if lo and hi and lo <= cursor and cursor <= hi then
          table.insert(results, {
            lo = lo,
            hi = hi,
            inverse = inverse,
            word = word,
          })
        end
      end
    end
  end

  -- Aucun résultat trouvé
  if #results == 0 then
    return log.warn('unsupported value.')
  end

  -- Un seul résultat : on applique directement
  if #results == 1 then
    return self.sub(line, results[1])
  end

  -- Plusieurs résultats : tri par longueur (du plus long au plus court)
  table.sort(results, function(a, b)
    return #a.word > #b.word
  end)

  -- Sélection automatique si le plus long est clairement dominant
  if app.opts.autoselect_longest_match and #results >= 2 then
    if #results[1].word > #results[2].word then
      return self.sub(line, results[1])
    end
  end

  -- Utilisation de vim.ui.select pour choisir
  vim.ui.select(results, {
    prompt = 'Choisissez une substitution:',
    format_item = function(result)
      return string.format('%s → %s', result.word, result.inverse)
    end,
  }, function(choice)
    if not choice then
      return log.echo('Aucun choix effectué.')
    end
    -- Récupérer la ligne actuelle (au cas où elle a changé)
    local current_line = vim.fn.getline('.')
    self.sub(current_line, choice)
    log.echo(('Toggled: %s → %s'):format(choice.word, choice.inverse))
  end)
end

function app:setup(opts)
  self:load_opts(defaults.opts)
  self:load_opts(opts)
  self.inv_tbl:reset()
  self.inv_tbl:add((opts or {}).inverses, true)
  if not self.opts.remove_default_inverses then
    self.inv_tbl:add(defaults.inverses)
  end
  for word, inverse in pairs(self.inv_tbl.data) do
    self.inv_tbl_metadata[word] = {
      has_only_lower_case = word == word:lower() and inverse == inverse:lower(),
    }
  end
  if not self.opts.remove_default_keybinds then
    vim.keymap.set(
      { 'n', 'v' },
      '<leader>i',
      function() self:toggle() end,
      { silent = true }
    )
  end
end

return {
  setup = function(opts) app:setup(opts) end,
  toggle = function() app:toggle() end,
  reset = function()
    app.inv_tbl:reset()
    app.opts = {}
  end,
}
