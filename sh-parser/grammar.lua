---------
-- LPeg grammar for POSIX shell.

local lpeg       = require 'lpeg'
local fun        = require 'sh-parser.fun_ext'
local lpeg_sugar = require 'sh-parser.lpeg_sugar'
local utils      = require 'sh-parser.utils'

local build_grammar = lpeg_sugar.build_grammar
local chain         = fun.chain
local iter          = fun.iter
local op            = fun.op
local par           = utils.partial
local unshift       = utils.unshift
local values        = utils.values

local B    = lpeg.B
local C    = lpeg.C
local Carg = lpeg.Carg
local Cb   = lpeg.Cb
local Cg   = lpeg.Cg
local Cs   = lpeg.Cs
local P    = lpeg.P
local R    = lpeg.R
local S    = lpeg.S


-- Terminals
local ALPHA   = R('AZ', 'az')
local ANY     = P(1)
local BOF     = P(function(_, pos) return pos == 1 end)  -- Beginning Of File
local DIGIT   = R('09')
local DQUOTE  = P('"')
local EOF     = P(-1)    -- End Of File
local EQUALS  = P('=')
local ESC     = P('\\')  -- escape character
local HASH    = P('#')
local LF      = P('\n')
local SQUOTE  = P("'")
local WSP     = S(' \t')

-- Shell operators containing single character.
local OPERATORS_1 = {
  AND       = '&',
  GREAT     = '>',
  LESS      = '<',
  LPAREN    = '(',
  PIPE      = '|',
  RPAREN    = ')',
  SEMI      = ';',
}
-- Shell operators containing more than one character.
local OPERATORS_2 = {
  AND_IF    = '&&',
  CLOBBER   = '>|',
  DGREAT    = '>>',
  DLESS     = '<<',
  DLESSDASH = '<<-',
  DSEMI     = ';;',
  GREATAND  = '>&',
  LESSAND   = '<&',
  LESSGREAT = '<>',
  OR_IF     = '||',
}

-- Shell reserved words.
local RESERVED_WORDS = {
  CASE      = 'case',
  DO        = 'do',
  DONE      = 'done',
  ELIF      = 'elif',
  ELSE      = 'else',
  ESAC      = 'esac',
  FI        = 'fi',
  FOR       = 'for',
  IF        = 'if',
  THEN      = 'then',
  UNTIL     = 'until',
  WHILE     = 'while',

  BANG      = '!',
  IN        = 'in',
  LBRACE    = '{',
  RBRACE    = '}',
}

-- Pattern that matches any character used in shell operators.
local operator_chars = values(OPERATORS_1):map(P):reduce(op.add, P(false))

-- XXX: is this correct?
local word_boundary = S(' \t\n') + BOF + EOF + operator_chars

local reserved_words = iter(RESERVED_WORDS)
    :map(function(k, v) return k, P(v) * #word_boundary end)

-- Pattern that matches any shell reserved word.
-- XXX: sort them?
local reserved_word = values(reserved_words):reduce(op.add, P(false))

-- Map of special terminal symbols (patterns).
local terminals = chain(
      iter(OPERATORS_1):map(function(k, v)
          -- Ensure that operator x does not match xx when xx is valid operator.
          return k, values(OPERATORS_2):index_of(v..v) and P(v) * -P(v) or P(v)
        end),
      iter(OPERATORS_2):map(function(k, v)
          return k, P(v)
        end),
      reserved_words
    ):tomap()


--- Creates a pattern that captures escaped `patt`.
--
-- @tparam lpeg.Pattern patt The pattern to escape.
-- @treturn lpeg.Pattern
local function escaped (patt)
  return patt == LF
      and ESC * patt / '' -- produce empty capture
      or ESC / '' * patt  -- omit escaping char from capture
end

--- Creates a pattern that captures quoted text.
--
-- @tparam string quote The quotation mark.
-- @treturn lpeg.Pattern
local function quoted (quote)
  return quote * Cs( (escaped(quote) + ANY - quote)^0 ) * quote
end

--- Skip already captured here-document.
--
-- This is a function for match-time capture that is called from grammar each
-- time when a new line is consumed. When the current position of the parser is
-- inside previously captured heredoc, then it returns position of the end of
-- that heredoc. Basically it teleports parser behind the heredoc.
--
-- @tparam int pos The current position.
-- @tparam {{int,int},...} heredocs (see `capture_heredoc`)
-- @treturn int The new current position.
local function skip_heredoc (_, pos, heredocs)
  -- Note: Elements are ordered from latest to earliest to optimize this lookup.
  -- Note: We cannot remove skipped heredocs in this function, because the
  --       matched rule may be eventually backtracked!
  for _, range in ipairs(heredocs) do
    local first, last = range[1], range[2]

    if pos > last then
      break
    elseif pos >= first and pos < last then
      return last
    end
  end

  return pos
end

--- Capture here-document.
--
-- @tparam bool strip_tabs Whether to strip leading tabs (for `<<-`).
-- @tparam string subject The entire subject (i.e. input text).
-- @tparam int pos The current position.
-- @tparam string word The captured delimiter word.
-- @tparam {{int,int},...} heredocs The list with positions of captured
--   heredocs. Each element is a list with two integers - position of the first
--   character inside heredoc and position of newline after closing delimiter.
-- @treturn true Consume no subject.
-- @treturn table Heredoc content.
local function capture_heredoc (strip_tabs, subject, pos, word, heredocs)
  local delimiter = word.children[1]

  local delim_pat = '\n'..(strip_tabs and '\t*' or '')
                        ..delimiter:gsub('%p', '%%%1')  -- escape puncatation chars
                        ..'\n'
  local doc_start = subject:find('\n', pos, true) or #subject
  local doc_end, delim_end = (subject..'\n'):find(delim_pat, doc_start)
  if not doc_end then
    doc_end, delim_end = #subject + 1, #subject
  end

  -- Skip overlapping heredocs (multiple heredoc redirects on the same line).
  while true do
    local new_pos = skip_heredoc(nil, doc_start, heredocs)
    if new_pos == doc_start then
      break
    end
    doc_start = new_pos
  end

  unshift(heredocs, { doc_start, delim_end or #subject })

  local content = subject:sub(doc_start, doc_end - 1)  -- keep leading newline
  content = strip_tabs and content:gsub('\n\t+', '\n') or content
  content = content:sub(2)  -- strip leading newline

  return true, content
end


--- Grammar to be processed by `lpeg_sugar`.
local function grammar (_ENV)  --luacheck: no unused args
  --luacheck: allow defined, ignore 113 131

  local _  = WSP^0  -- optional whitespace(s)
  local __ = WSP^1  -- at least one whitespace
  local heredocs_index = Carg(1)  -- state table used for skipping heredocs

  Program             = linebreak * ( complete_commands * linebreak )^-1 * EOF
  complete_commands   = CompleteCommand * ( newline_list * CompleteCommand )^0
  CompleteCommand     = and_or * ( separator_op * and_or )^0 * separator_op^-1
                      -- Note: Anonymous Cg is here only to exclude named Cg from capture in AST.
  and_or              = Cg( Cg(pipeline, 'pipeline') * ( AndList
                                                       + OrList
                                                       + Cb'pipeline' ) )
  AndList             = Cb'pipeline' * _ * AND_IF * linebreak * and_or
  OrList              = Cb'pipeline' * _ * OR_IF * linebreak * and_or
  pipeline            = Not
                      + pipe_sequence
  Not                 = BANG * __ * pipe_sequence
  pipe_sequence       = Cg( Cg(command, 'command') * ( PipeSequence
                                                     + Cb'command' ) )
  PipeSequence        = Cb'command' * ( _ * PIPE * linebreak * command )^1
  command             = FunctionDefinition
                      + compound_command * io_redirect^0
                      + SimpleCommand
  compound_command    = BraceGroup
                      + Subshell
                      + ForClause
                      + CaseClause
                      + IfClause
                      + WhileClause
                      + UntilClause
  Subshell            = LPAREN * compound_list * _ * RPAREN * _
  compound_list       = linebreak * term * separator^-1
  term                = and_or * ( separator * and_or )^0
  ForClause           = FOR * __ * Name * ( sequential_sep
                                          + linebreak * IN * ( __ * Word )^0 * sequential_sep
                                          + _ )
                                        * do_group
  CaseClause          = CASE * __ * Word * linebreak
                        * IN * linebreak
                        * ( CaseItem * _ * DSEMI * linebreak )^0
                        * CaseItem^-1
                        * ESAC
  CaseItem            = ( LPAREN * _ )^-1 * Pattern * _ * RPAREN
                        * ( compound_list + linebreak )
  Pattern             = ( Word - ESAC ) * ( _ * PIPE * _ * Word )^0
  IfClause            = IF * linebreak
                        * term * separator
                        * THEN * compound_list
                        * elif_part^0
                        * else_part^-1
                        * FI
  elif_part           = ELIF * compound_list
                        * THEN * compound_list
  else_part           = ELSE * compound_list
  WhileClause         = WHILE * compound_list
                        * do_group
  UntilClause         = UNTIL * compound_list
                        * do_group
  FunctionDefinition  = ( Name - reserved_word ) * _ * LPAREN * _ * RPAREN * linebreak
                        * function_body
  function_body       = compound_command * io_redirect^0
  BraceGroup          = LBRACE * compound_list * RBRACE
  do_group            = DO * compound_list * DONE
  SimpleCommand       = cmd_prefix * ( __ * CmdName * cmd_suffix^-1 )^-1
                      + CmdName * cmd_suffix^-1
  CmdName             = Word - reserved_word
  cmd_prefix          = ( io_redirect + Assignment ) * ( __ * cmd_prefix )^-1
  cmd_suffix          = ( __ * ( io_redirect + CmdArgument ) )^1
  CmdArgument         = Word
  io_redirect         = IORedirectFile
                      + IOHereDoc
  IORedirectFile      = io_number^-1 * io_file_op * _ * Word
  IOHereDoc           = io_number^-1 * (
                            DLESSDASH * _ * Cmt(Word * heredocs_index, par(capture_heredoc, true))
                          + DLESS * _ * Cmt(Word * heredocs_index, par(capture_heredoc, false))
                        )
  io_number           = C( DIGIT^1 ) / tonumber
  io_file_op          = C( GREATAND + DGREAT + CLOBBER + LESSAND + LESSGREAT + GREAT + LESS )
  separator_op        = _ * ( AND + SEMI ) * _
  separator           = separator_op * linebreak
                      + newline_list
  sequential_sep      = _ * SEMI * linebreak
                      + newline_list
  Assignment          = Name * EQUALS * Word^-1
  Name                = C( ( ALPHA + '_' ) * ( ALPHA + DIGIT + '_' )^0 )
  Word                = ( quoted(DQUOTE)
                        + quoted(SQUOTE)
                        + Cs( -HASH * unquoted_char^1 )
                        )^1
  unquoted_char       = escaped(LF) + escaped(WSP + SQUOTE + DQUOTE + operator_chars)
                      + ( ANY - LF - WSP - SQUOTE - DQUOTE - operator_chars )
  newline_list        = ( _ * Comment^-1 * LF * Cmt(heredocs_index, skip_heredoc) )^1 * _
  linebreak           = _ * newline_list^-1
  Comment             = ( B(WSP) + B(LF) + B(SEMI) + B(AND) + #BOF )
                        * HASH * C( ( ANY - LF )^0 )
end


return function ()
  return build_grammar(grammar, terminals)
end
