module Lexers

@static if Meta.parse("a .&& b").args[1] != :.&
    const CAN_DOT_LAZY_AND_OR = true
else
    const CAN_DOT_LAZY_AND_OR = false
end

include("utilities.jl")

import ..Tokens
import ..Tokens: AbstractToken, Token, RawToken, Kind, TokenError, UNICODE_OPS, EMPTY_TOKEN, isliteral

import ..Tokens: FUNCTION, ABSTRACT, IDENTIFIER, BAREMODULE, BEGIN, BREAK, CATCH, CONST, CONTINUE,
                 DO, ELSE, ELSEIF, END, EXPORT, FALSE, FINALLY, FOR, FUNCTION, GLOBAL, LET, LOCAL, IF,
                 IMPORT, IMPORTALL, MACRO, MODULE, OUTER, QUOTE, RETURN, TRUE, TRY, TYPE, USING, WHILE, ISA, IN,
                 MUTABLE, PRIMITIVE, PUBLIC, STRUCT, WHERE


export tokenize

@inline ishex(c::Char) = isdigit(c) || ('a' <= c <= 'f') || ('A' <= c <= 'F')
@inline isbinary(c::Char) = c == '0' || c == '1'
@inline isoctal(c::Char) =  '0' ≤ c ≤ '7'
@inline iswhitespace(c::Char) = Base.isspace(c) || c === '\ufeff'

mutable struct Lexer{IO_t <: IO, T <: AbstractToken}
    io::IO_t
    io_startpos::Int

    token_start_row::Int
    token_start_col::Int
    token_startpos::Int

    current_row::Int
    current_col::Int
    current_pos::Int

    last_token::Tokens.Kind
    charstore::IOBuffer
    chars::Tuple{Char,Char,Char}
    charspos::Tuple{Int,Int,Int}
    doread::Bool
    dotop::Bool
end

function Lexer(io::IO_t, T::Type{TT} = Token) where {IO_t,TT <: AbstractToken}
    c1 = ' '
    p1 = position(io)
    if eof(io)
        c2, p2 = EOF_CHAR, p1
        c3, p3 = EOF_CHAR, p1
    else
        c2 = read(io, Char)
        p2 = position(io)
        if eof(io)
            c3, p3 = EOF_CHAR, p1
        else
            c3 = read(io, Char)
            p3 = position(io)
        end

    end
    Lexer{IO_t,T}(io, position(io), 1, 1, position(io), 1, 1, position(io), Tokens.ERROR, IOBuffer(), (c1,c2,c3), (p1,p2,p3), false, false)
end
Lexer(str::AbstractString, T::Type{TT} = Token) where TT <: AbstractToken = Lexer(IOBuffer(str), T)

@inline token_type(l::Lexer{IO_t, TT}) where {IO_t, TT} = TT

"""
    tokenize(x, T = Token)

Returns an `Iterable` containing the tokenized input. Can be reverted by e.g.
`join(untokenize.(tokenize(x)))`. Setting `T` chooses the type of token
produced by the lexer (`Token` or `RawToken`).
"""
tokenize(x, ::Type{Token}) = Lexer(x, Token)
tokenize(x, ::Type{RawToken}) = Lexer(x, RawToken)
tokenize(x) = Lexer(x, Token)

# Iterator interface
Base.IteratorSize(::Type{Lexer{IO_t,T}}) where {IO_t,T} = Base.SizeUnknown()
Base.IteratorEltype(::Type{Lexer{IO_t,T}}) where {IO_t,T} = Base.HasEltype()
Base.eltype(::Type{Lexer{IO_t,T}}) where {IO_t,T} = T


function Base.iterate(l::Lexer)
    seekstart(l)
    l.token_startpos = position(l)
    l.token_start_row = 1
    l.token_start_col = 1

    l.current_row = 1
    l.current_col = 1
    l.current_pos = l.io_startpos
    t = next_token(l)
    return t, t.kind == Tokens.ENDMARKER
end

function Base.iterate(l::Lexer, isdone::Any)
    isdone && return nothing
    t = next_token(l)
    return t, t.kind == Tokens.ENDMARKER
end

function Base.show(io::IO, l::Lexer)
    print(io, typeof(l), " at position: ", position(l))
end

"""
    startpos(l::Lexer)

Return the latest `Token`'s starting position.
"""
startpos(l::Lexer) = l.token_startpos

"""
    startpos!(l::Lexer, i::Integer)

Set a new starting position.
"""
startpos!(l::Lexer, i::Integer) = l.token_startpos = i

Base.seekstart(l::Lexer) = seek(l.io, l.io_startpos)

"""
    seek2startpos!(l::Lexer)

Sets the lexer's current position to the beginning of the latest `Token`.
"""
seek2startpos!(l::Lexer) = seek(l, startpos(l))

"""
    peekchar(l::Lexer)

Returns the next character without changing the lexer's state.
"""
peekchar(l::Lexer) = l.chars[2]

"""
dpeekchar(l::Lexer)

Returns the next two characters without changing the lexer's state.
"""
dpeekchar(l::Lexer) = l.chars[2], l.chars[3]

"""
    position(l::Lexer)

Returns the current position.
"""
Base.position(l::Lexer) = l.charspos[1]

"""
    eof(l::Lexer)

Determine whether the end of the lexer's underlying buffer has been reached.
"""# Base.position(l::Lexer) = Base.position(l.io)
eof(l::Lexer) = eof(l.io)

Base.seek(l::Lexer, pos) = seek(l.io, pos)

"""
    start_token!(l::Lexer)

Updates the lexer's state such that the next  `Token` will start at the current
position.
"""
function start_token!(l::Lexer)
    l.token_startpos = l.charspos[1]
    l.token_start_row = l.current_row
    l.token_start_col = l.current_col
end

"""
    readchar(l::Lexer)

Returns the next character and increments the current position.
"""
function readchar end

function readchar(l::Lexer{I}) where {I <: IO}
    c = readchar(l.io)
    l.chars = (l.chars[2], l.chars[3], c)
    l.charspos = (l.charspos[2], l.charspos[3], position(l.io))
    if l.doread
        write(l.charstore, l.chars[1])
    end
    if l.chars[1] == '\n'
        l.current_row += 1
        l.current_col = 1
    elseif !eof(l.chars[1])
        l.current_col += 1
    end
    return l.chars[1]
end

readon(l::Lexer{I,RawToken}) where {I <: IO} = l.chars[1]
function readon(l::Lexer{I,Token}) where {I <: IO}
    if l.charstore.size != 0
        take!(l.charstore)
    end
    write(l.charstore, l.chars[1])
    l.doread = true
end

readoff(l::Lexer{I,RawToken}) where {I <: IO} = l.chars[1]
function readoff(l::Lexer{I,Token})  where {I <: IO}
    l.doread = false
    return l.chars[1]
end

"""
    accept(l::Lexer, f::Union{Function, Char, Vector{Char}, String})

Consumes the next character `c` if either `f::Function(c)` returns true, `c == f`
for `c::Char` or `c in f` otherwise. Returns `true` if a character has been
consumed and `false` otherwise.
"""
@inline function accept(l::Lexer, f::Union{Function, Char, Vector{Char}, String})
    c = peekchar(l)
    if isa(f, Function)
        ok = f(c)
    elseif isa(f, Char)
        ok = c == f
    else
        ok = c in f
    end
    ok && readchar(l)
    return ok
end

"""
    accept_batch(l::Lexer, f)

Consumes all following characters until `accept(l, f)` is `false`.
"""
@inline function accept_batch(l::Lexer, f)
    ok = false
    while accept(l, f)
        ok = true
    end
    return ok
end

"""
    emit(l::Lexer, kind::Kind, err::TokenError=Tokens.NO_ERR)

Returns a `Token` of kind `kind` with contents `str` and starts a new `Token`.
"""
function emit(l::Lexer{IO_t,Token}, kind::Kind, err::TokenError = Tokens.NO_ERR) where IO_t
    suffix = false
    if kind in (Tokens.ERROR, Tokens.STRING, Tokens.TRIPLE_STRING, Tokens.CMD, Tokens.TRIPLE_CMD)
        str = String(l.io.data[(l.token_startpos + 1):position(l)])
    elseif (kind == Tokens.IDENTIFIER || isliteral(kind) || kind == Tokens.COMMENT || kind == Tokens.WHITESPACE)
        str = String(take!(l.charstore))
    elseif optakessuffix(kind)
        str = ""
        while isopsuffix(peekchar(l))
            str = string(str, readchar(l))
            suffix = true
        end
    else
        str = ""
    end
    tok = Token(kind, (l.token_start_row, l.token_start_col),
            (l.current_row, l.current_col - 1),
            startpos(l), position(l) - 1,
            str, err, l.dotop, suffix)
    l.dotop = false
    l.last_token = kind
    readoff(l)
    return tok
end

function emit(l::Lexer{IO_t,RawToken}, kind::Kind, err::TokenError = Tokens.NO_ERR) where IO_t
    suffix = false
    if optakessuffix(kind)
        while isopsuffix(peekchar(l))
            readchar(l)
            suffix = true
        end
    end

    tok = RawToken(kind, (l.token_start_row, l.token_start_col),
                  (l.current_row, l.current_col - 1),
                  startpos(l), position(l) - 1, err, l.dotop, suffix)

    l.dotop = false
    l.last_token = kind
    readoff(l)
    return tok
end

"""
    emit_error(l::Lexer, err::TokenError=Tokens.UNKNOWN)

Returns an `ERROR` token with error `err` and starts a new `Token`.
"""
function emit_error(l::Lexer, err::TokenError = Tokens.UNKNOWN)
    return emit(l, Tokens.ERROR, err)
end

function is_identifier_start_char(c::Char)
    c == EOF_CHAR && return false
    return Base.is_id_start_char(c)
end

"""
    next_token(l::Lexer)

Returns the next `Token`.
"""
function next_token(l::Lexer, start = true)
    start && start_token!(l)
    c = readchar(l)
    if eof(c)
        return emit(l, Tokens.ENDMARKER)
    elseif iswhitespace(c)
        return lex_whitespace(l)
    elseif c == '['
        return emit(l, Tokens.LSQUARE)
    elseif c == ']'
        return emit(l, Tokens.RSQUARE)
    elseif c == '{'
        return emit(l, Tokens.LBRACE)
    elseif c == ';'
        return emit(l, Tokens.SEMICOLON)
    elseif c == '}'
        return emit(l, Tokens.RBRACE)
    elseif c == '('
        return emit(l, Tokens.LPAREN)
    elseif c == ')'
        return emit(l, Tokens.RPAREN)
    elseif c == ','
        return emit(l, Tokens.COMMA)
    elseif c == '*'
        return lex_star(l);
    elseif c == '^'
        return lex_circumflex(l);
    elseif c == '@'
        return emit(l, Tokens.AT_SIGN)
    elseif c == '?'
        return emit(l, Tokens.CONDITIONAL)
    elseif c == '$'
        return lex_dollar(l);
    elseif c == '⊻'
        return lex_xor(l);
    elseif c == '~'
        return emit(l, Tokens.APPROX)
    elseif c == '#'
        return lex_comment(l)
    elseif c == '='
        return lex_equal(l)
    elseif c == '!'
        return lex_exclaim(l)
    elseif c == '>'
        return lex_greater(l)
    elseif c == '<'
        return lex_less(l)
    elseif c == ':'
        return lex_colon(l)
    elseif c == '|'
        return lex_bar(l)
    elseif c == '&'
        return lex_amper(l)
    elseif c == '\''
        return lex_prime(l)
    elseif c == '÷'
        return lex_division(l)
    elseif c == '"'
        return lex_quote(l);
    elseif c == '%'
        return lex_percent(l);
    elseif c == '/'
        return lex_forwardslash(l);
    elseif c == '\\'
        return lex_backslash(l);
    elseif c == '.'
        return lex_dot(l);
    elseif c == '+'
        return lex_plus(l);
    elseif c == '-'
        return lex_minus(l);
    elseif c == '`'
        return lex_cmd(l);
    elseif is_identifier_start_char(c)
        return lex_identifier(l, c)
    elseif isdigit(c)
        return lex_digit(l, Tokens.INTEGER)
    elseif (k = get(UNICODE_OPS, c, Tokens.ERROR)) != Tokens.ERROR
        return emit(l, k)
    else
        emit_error(l)
    end
end


# Lex whitespace, a whitespace char has been consumed
function lex_whitespace(l::Lexer)
    readon(l)
    accept_batch(l, iswhitespace)
    return emit(l, Tokens.WHITESPACE)
end

function lex_comment(l::Lexer)
    readon(l)
    if peekchar(l) != '='
        while true
            pc = peekchar(l)
            if pc == '\n' || eof(pc)
                return emit(l, Tokens.COMMENT)
            end
            readchar(l)
        end
    else
        c = readchar(l) # consume the '='
        skip = true  # true => c was part of the prev comment marker pair
        nesting = 1
        while true
            if eof(c)
                return emit_error(l, Tokens.EOF_MULTICOMMENT)
            end
            nc = readchar(l)
            if skip
                skip = false
            else
                if c == '#' && nc == '='
                    nesting += 1
                    skip = true
                elseif c == '=' && nc == '#'
                    nesting -= 1
                    skip = true
                    if nesting == 0
                        return emit(l, Tokens.COMMENT)
                    end
                end
            end
            c = nc
        end
    end
end

# Lex a greater char, a '>' has been consumed
function lex_greater(l::Lexer)
    if accept(l, '>') # >>
        if accept(l, '>') # >>>
            if accept(l, '=') # >>>=
                return emit(l, Tokens.UNSIGNED_BITSHIFT_EQ)
            else # >>>?, ? not a =
                return emit(l, Tokens.UNSIGNED_BITSHIFT)
            end
        elseif accept(l, '=') # >>=
            return emit(l, Tokens.RBITSHIFT_EQ)
        else # '>>'
            return emit(l, Tokens.RBITSHIFT)
        end
    elseif accept(l, '=') # >=
        return emit(l, Tokens.GREATER_EQ)
    elseif accept(l, ':') # >:
        return emit(l, Tokens.ISSUPERTYPE)
    else  # '>'
        return emit(l, Tokens.GREATER)
    end
end

# Lex a less char, a '<' has been consumed
function lex_less(l::Lexer)
    if accept(l, '<') # <<
        if accept(l, '=') # <<=
            return emit(l, Tokens.LBITSHIFT_EQ)
        else # '<<?', ? not =, ' '
            return emit(l, Tokens.LBITSHIFT)
        end
    elseif accept(l, '=') # <=
        return emit(l, Tokens.LESS_EQ)
    elseif accept(l, ':')
        return emit(l, Tokens.ISSUBTYPE)
    elseif accept(l, '|') # <|
        return emit(l, Tokens.LPIPE)
    elseif dpeekchar(l) == ('-', '-') # <-- or <-->
        readchar(l); readchar(l)
        if accept(l, '>')
            return emit(l, Tokens.DOUBLE_ARROW)
        else
            return emit(l, Tokens.LEFT_ARROW)
        end
    else
        return emit(l, Tokens.LESS) # '<'
    end
end

# Lex all tokens that start with an = character.
# An '=' char has been consumed
function lex_equal(l::Lexer)
    if accept(l, '=') # ==
        if accept(l, '=') # ===
            emit(l, Tokens.EQEQEQ)
        else
            emit(l, Tokens.EQEQ)
        end
    elseif accept(l, '>') # =>
        emit(l, Tokens.PAIR_ARROW)
    else
        emit(l, Tokens.EQ)
    end
end

# Lex a colon, a ':' has been consumed
function lex_colon(l::Lexer)
    if accept(l, ':') # '::'
        return emit(l, Tokens.DECLARATION)
    elseif accept(l, '=') # ':='
        return emit(l, Tokens.COLON_EQ)
    else
        return emit(l, Tokens.COLON)
    end
end

function lex_exclaim(l::Lexer)
    if accept(l, '=') # !=
        if accept(l, '=') # !==
            return emit(l, Tokens.NOT_IS)
        else # !=
            return emit(l, Tokens.NOT_EQ)
        end
    else
        return emit(l, Tokens.NOT)
    end
end

function lex_percent(l::Lexer)
    if accept(l, '=')
        return emit(l, Tokens.REM_EQ)
    else
        return emit(l, Tokens.REM)
    end
end

function lex_bar(l::Lexer)
    if accept(l, '=') # |=
        return emit(l, Tokens.OR_EQ)
    elseif accept(l, '>') # |>
        return emit(l, Tokens.RPIPE)
    elseif accept(l, '|') # ||
        return emit(l, Tokens.LAZY_OR)
    else
        emit(l, Tokens.OR) # '|'
    end
end

function lex_plus(l::Lexer)
    if accept(l, '+')
        return emit(l, Tokens.PLUSPLUS)
    elseif accept(l, '=')
        return emit(l, Tokens.PLUS_EQ)
    end
    return emit(l, Tokens.PLUS)
end

function lex_minus(l::Lexer)
    if accept(l, '-')
        if accept(l, '>')
            return emit(l, Tokens.RIGHT_ARROW)
        else
            return emit_error(l, Tokens.INVALID_OPERATOR) # "--" is an invalid operator
        end
    elseif accept(l, '>')
        return emit(l, Tokens.ANON_FUNC)
    elseif accept(l, '=')
        return emit(l, Tokens.MINUS_EQ)
    end
    return emit(l, Tokens.MINUS)
end

function lex_star(l::Lexer)
    if accept(l, '*')
        return emit_error(l, Tokens.INVALID_OPERATOR) # "**" is an invalid operator use ^
    elseif accept(l, '=')
        return emit(l, Tokens.STAR_EQ)
    end
    return emit(l, Tokens.STAR)
end

function lex_circumflex(l::Lexer)
    if accept(l, '=')
        return emit(l, Tokens.CIRCUMFLEX_EQ)
    end
    return emit(l, Tokens.CIRCUMFLEX_ACCENT)
end

function lex_division(l::Lexer)
    if accept(l, '=')
        return emit(l, Tokens.DIVISION_EQ)
    end
    return emit(l, Tokens.DIVISION_SIGN)
end

function lex_dollar(l::Lexer)
    if accept(l, '=')
        return emit(l, Tokens.EX_OR_EQ)
    end
    return emit(l, Tokens.EX_OR)
end

function lex_xor(l::Lexer)
    if accept(l, '=')
        return emit(l, Tokens.XOR_EQ)
    end
    return emit(l, Tokens.XOR)
end

function accept_number(l::Lexer, f::F) where {F}
    while true
        pc, ppc = dpeekchar(l)
        if pc == '_' && !f(ppc)
            return
        elseif f(pc) || pc == '_'
            readchar(l)
        else
            return
        end
    end
end

# A digit has been consumed
function lex_digit(l::Lexer, kind)
    readon(l)
    accept_number(l, isdigit)
    pc,ppc = dpeekchar(l)
    if pc == '.'
        if ppc == '.'
            # Number followed by .. or ...
            return emit(l, kind)
        elseif kind === Tokens.FLOAT
            # If we enter the function with kind == FLOAT then a '.' has been parsed.
            readchar(l)
            return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
        elseif is_operator_start_char(ppc) && ppc !== ':'
            readchar(l)
            return emit_error(l)
        elseif (!(isdigit(ppc) ||
            iswhitespace(ppc) ||
            is_identifier_start_char(ppc)
            || ppc == '('
            || ppc == ')'
            || ppc == '['
            || ppc == ']'
            || ppc == '{'
            || ppc == '}'
            || ppc == ','
            || ppc == ';'
            || ppc == '@'
            || ppc == '`'
            || ppc == '"'
            || ppc == ':'
            || ppc == '?'
            || eof(ppc)))
            kind = Tokens.INTEGER

            return emit(l, kind)
        end
        readchar(l)

        kind = Tokens.FLOAT
        accept_number(l, isdigit)
        pc, ppc = dpeekchar(l)
        if (pc == 'e' || pc == 'E' || pc == 'f') && (isdigit(ppc) || ppc == '+' || ppc == '-')
            kind = Tokens.FLOAT
            readchar(l)
            accept(l, "+-")
            if accept_batch(l, isdigit)
                pc,ppc = dpeekchar(l)
                if pc === '.' && !dotop2(ppc, ' ')
                    accept(l, '.')
                    return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
                end
            else
                return emit_error(l)
            end
        elseif pc == '.' && (is_identifier_start_char(ppc) || eof(ppc))
            readchar(l)
            return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
        end

    elseif (pc == 'e' || pc == 'E' || pc == 'f') && (isdigit(ppc) || ppc == '+' || ppc == '-')
        kind = Tokens.FLOAT
        readchar(l)
        accept(l, "+-")
        if accept_batch(l, isdigit)
            pc,ppc = dpeekchar(l)
            if pc === '.' && !dotop2(ppc, ' ')
                accept(l, '.')
                return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
            end
        else
            return emit_error(l)
        end
    elseif position(l) - startpos(l) == 1 && l.chars[1] == '0'
        kind == Tokens.INTEGER
        if pc == 'x'
            kind = Tokens.HEX_INT
            isfloat = false
            readchar(l)
            !(ishex(ppc) || ppc == '.') && return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
            accept_number(l, ishex)
            pc,ppc = dpeekchar(l)
            if pc == '.' && ppc != '.'
                readchar(l)
                accept_number(l, ishex)
                isfloat = true
            end
            if accept(l, "pP")
                kind = Tokens.FLOAT
                accept(l, "+-")
                accept_number(l, isdigit)
            elseif isfloat
                return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
            end
        elseif pc == 'b'
            !isbinary(ppc) && return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
            readchar(l)
            accept_number(l, isbinary)
            kind = Tokens.BIN_INT
        elseif pc == 'o'
            !isoctal(ppc) && return emit_error(l, Tokens.INVALID_NUMERIC_CONSTANT)
            readchar(l)
            accept_number(l, isoctal)
            kind = Tokens.OCT_INT
        end
    end
    return emit(l, kind)
end

function lex_prime(l, doemit = true)
    if l.last_token == Tokens.IDENTIFIER ||
        l.last_token == Tokens.DOT ||
        l.last_token ==  Tokens.RPAREN ||
        l.last_token ==  Tokens.RSQUARE ||
        l.last_token ==  Tokens.RBRACE ||
        l.last_token == Tokens.PRIME ||
        l.last_token == Tokens.END || isliteral(l.last_token)
        return emit(l, Tokens.PRIME)
    else
        readon(l)
        if accept(l, '\'')
            if accept(l, '\'')
                return doemit ? emit(l, Tokens.CHAR) : EMPTY_TOKEN(token_type(l))
            else
                # Empty char literal
                # Arguably this should be an error here, but we generally
                # look at the contents of the char literal in the parser,
                # so we defer erroring until there.
                return doemit ? emit(l, Tokens.CHAR) : EMPTY_TOKEN(token_type(l))
            end
        end
        while true
            c = readchar(l)
            if eof(c)
                return doemit ? emit_error(l, Tokens.EOF_CHAR) : EMPTY_TOKEN(token_type(l))
            elseif c == '\\'
                if eof(readchar(l))
                    return doemit ? emit_error(l, Tokens.EOF_CHAR) : EMPTY_TOKEN(token_type(l))
                end
            elseif c == '\''
                return doemit ? emit(l, Tokens.CHAR) : EMPTY_TOKEN(token_type(l))
            end
        end
    end
end

function lex_amper(l::Lexer)
    if accept(l, '&')
        return emit(l, Tokens.LAZY_AND)
    elseif accept(l, "=")
        return emit(l, Tokens.AND_EQ)
    else
        return emit(l, Tokens.AND)
    end
end

# Parse a token starting with a quote.
# A '"' has been consumed
function lex_quote(l::Lexer, doemit=true)
    readon(l)
    if accept(l, '"') # ""
        if accept(l, '"') # """
            if read_string(l, Tokens.TRIPLE_STRING)
                return doemit ? emit(l, Tokens.TRIPLE_STRING) : EMPTY_TOKEN(token_type(l))
            else
                return doemit ? emit_error(l, Tokens.EOF_STRING) : EMPTY_TOKEN(token_type(l))
            end
        else # empty string
            return doemit ? emit(l, Tokens.STRING) : EMPTY_TOKEN(token_type(l))
        end
    else # "?, ? != '"'
        if read_string(l, Tokens.STRING)
            return doemit ? emit(l, Tokens.STRING) : EMPTY_TOKEN(token_type(l))
        else
            return doemit ? emit_error(l, Tokens.EOF_STRING) : EMPTY_TOKEN(token_type(l))
        end
    end
end

function string_terminated(l, kind::Tokens.Kind)
    if kind == Tokens.STRING && l.chars[1] == '"'
        return true
    elseif kind == Tokens.TRIPLE_STRING && l.chars[1] == l.chars[2] == l.chars[3] == '"'
        readchar(l)
        readchar(l)
        return true
    elseif kind == Tokens.CMD && l.chars[1] == '`'
        return true
    elseif kind == Tokens.TRIPLE_CMD && l.chars[1] == l.chars[2] == l.chars[3] == '`'
        readchar(l)
        readchar(l)
        return true
    end
    return false
end

# We just consumed a ", """, `, or ```
function read_string(l::Lexer, kind::Tokens.Kind)
    can_interpolate = l.last_token !== Tokens.IDENTIFIER
    while true
        c = readchar(l)
        if c == '\\'
            eof(readchar(l)) && return false
            continue
        end
        if string_terminated(l, kind)
            return true
        elseif eof(c)
            return false
        end
        if can_interpolate && c == '$'
            c = readchar(l)
            if string_terminated(l, kind)
                return true
            elseif eof(c)
                return false
            elseif c == '('
                o = 1
                last_token = l.last_token
                token_start_row = l.token_start_row
                token_start_col = l.token_start_col
                token_startpos = l.token_startpos
                while o > 0
                    t = next_token(l)

                    if Tokens.kind(t) == Tokens.ENDMARKER
                        l.last_token = last_token
                        l.token_start_row = token_start_row
                        l.token_start_col = token_start_col
                        l.token_startpos = token_startpos
                        return false
                    elseif Tokens.kind(t) == Tokens.LPAREN
                        o += 1
                    elseif Tokens.kind(t) == Tokens.RPAREN
                        o -= 1
                    end
                end
                l.last_token = last_token
                l.token_start_row = token_start_row
                l.token_start_col = token_start_col
                l.token_startpos = token_startpos
            end
        end
    end
end

# Parse a token starting with a forward slash.
# A '/' has been consumed
function lex_forwardslash(l::Lexer)
    if accept(l, "/") # //
        if accept(l, "=") # //=
            return emit(l, Tokens.FWDFWD_SLASH_EQ)
        else
            return emit(l, Tokens.FWDFWD_SLASH)
        end
    elseif accept(l, "=") # /=
        return emit(l, Tokens.FWD_SLASH_EQ)
    else
        return emit(l, Tokens.FWD_SLASH)
    end
end

function lex_backslash(l::Lexer)
    if accept(l, '=')
        return emit(l, Tokens.BACKSLASH_EQ)
    end
    return emit(l, Tokens.BACKSLASH)
end

# TODO .op
function lex_dot(l::Lexer)
    if accept(l, '.')
        if accept(l, '.')
            return emit(l, Tokens.DDDOT)
        else
            return emit(l, Tokens.DDOT)
        end
    elseif Base.isdigit(peekchar(l))
        return lex_digit(l, Tokens.FLOAT)
    else
        pc, dpc = dpeekchar(l)
        if dotop1(pc)
            l.dotop = true
            return next_token(l, false)
        elseif pc =='+'
            l.dotop = true
            readchar(l)
            return lex_plus(l)
        elseif pc =='-'
            l.dotop = true
            readchar(l)
            return lex_minus(l)
        elseif pc =='*'
            l.dotop = true
            readchar(l)
            return lex_star(l)
        elseif pc =='/'
            l.dotop = true
            readchar(l)
            return lex_forwardslash(l)
        elseif pc =='\\'
            l.dotop = true
            readchar(l)
            return lex_backslash(l)
        elseif pc =='^'
            l.dotop = true
            readchar(l)
            return lex_circumflex(l)
        elseif pc =='<'
            l.dotop = true
            readchar(l)
            return lex_less(l)
        elseif pc =='>'
            l.dotop = true
            readchar(l)
            return lex_greater(l)
        elseif pc =='&'
            l.dotop = true
            readchar(l)
            if accept(l, "=")
                return emit(l, Tokens.AND_EQ)
            else
                @static if CAN_DOT_LAZY_AND_OR
                    if accept(l, "&")
                        return emit(l, Tokens.LAZY_AND)
                    end
                end
                return emit(l, Tokens.AND)
            end
        elseif pc =='%'
            l.dotop = true
            readchar(l)
            return lex_percent(l)
        elseif pc == '=' && dpc != '>'
            l.dotop = true
            readchar(l)
            return lex_equal(l)
        elseif pc == '|'
            @static if !CAN_DOT_LAZY_AND_OR
                if dpc == '|'
                    return emit(l, Tokens.DOT)
                end
            end
            l.dotop = true
            readchar(l)
            @static if CAN_DOT_LAZY_AND_OR
                if accept(l, "|")
                    return emit(l, Tokens.LAZY_OR)
                end
            end
            return lex_bar(l)
        elseif pc == '!' && dpc == '='
            l.dotop = true
            readchar(l)
            return lex_exclaim(l)
        elseif pc == '⊻'
            l.dotop = true
            readchar(l)
            return lex_xor(l)
        elseif pc == '÷'
            l.dotop = true
            readchar(l)
            return lex_division(l)
        elseif pc == '=' && dpc == '>'
            l.dotop = true
            readchar(l)
            return lex_equal(l)
        end
        return emit(l, Tokens.DOT)
    end
end

# A ` has been consumed
function lex_cmd(l::Lexer, doemit=true)
    readon(l)
    if accept(l, '`') #
        if accept(l, '`') # """
            if read_string(l, Tokens.TRIPLE_CMD)
                return doemit ? emit(l, Tokens.TRIPLE_CMD) : EMPTY_TOKEN(token_type(l))
            else
                return doemit ? emit_error(l, Tokens.EOF_CMD) : EMPTY_TOKEN(token_type(l))
            end
        else # empty cmd
            return doemit ? emit(l, Tokens.CMD) : EMPTY_TOKEN(token_type(l))
        end
    else
        if read_string(l, Tokens.CMD)
            return doemit ? emit(l, Tokens.CMD) : EMPTY_TOKEN(token_type(l))
        else
            return doemit ? emit_error(l, Tokens.EOF_CMD) : EMPTY_TOKEN(token_type(l))
        end
    end
end

function is_identifier_char(c::Char)
    c == EOF_CHAR && return false
    return Base.is_id_char(c)
end

const MAX_KW_LENGTH = 10

function lex_identifier(l::Lexer{IO_t,T}, c) where {IO_t,T}
    if T == Token
        readon(l)
    end
    h = simple_hash(c, UInt64(0))
    n = 1
    while true
        pc, ppc = dpeekchar(l)
        if (pc == '!' && ppc == '=') || !is_identifier_char(pc)
            break
        end
        c = readchar(l)
        h = simple_hash(c, h)
        n += 1
    end

    if n > MAX_KW_LENGTH
        emit(l, IDENTIFIER)
    else
        emit(l, get(kw_hash, h, IDENTIFIER))
    end
end

# A perfect hash for lowercase ascii words less than 13 characters. We use this
# to uniquely distinguish keywords; the hash for a keyword must be distinct
# from the hash of any other possible identifier. Needs an additional length
# check for words longer than the longest keyword.
@inline function simple_hash(c::Char, h::UInt64)
    bytehash = (clamp(c - 'a' + 1, -1, 30) % UInt8) & 0x1f
    h << 5 + bytehash
end

function simple_hash(str)
    ind = 1
    h = UInt64(0)
    L = length(str)
    while ind <= L
        h = simple_hash(str[ind], h)
        ind = nextind(str, ind)
    end
    h
end

kws = [
Tokens.ABSTRACT,
Tokens.BAREMODULE,
Tokens.BEGIN,
Tokens.BREAK,
Tokens.CATCH,
Tokens.CONST,
Tokens.CONTINUE,
Tokens.DO,
Tokens.ELSE,
Tokens.ELSEIF,
Tokens.END,
Tokens.EXPORT,
Tokens.FINALLY,
Tokens.FOR,
Tokens.FUNCTION,
Tokens.GLOBAL,
Tokens.IF,
Tokens.IMPORT,
Tokens.IMPORTALL,
Tokens.LET,
Tokens.LOCAL,
Tokens.MACRO,
Tokens.MODULE,
Tokens.MUTABLE,
Tokens.OUTER,
Tokens.PRIMITIVE,
Tokens.PUBLIC,
Tokens.QUOTE,
Tokens.RETURN,
Tokens.STRUCT,
Tokens.TRY,
Tokens.TYPE,
Tokens.USING,
Tokens.WHILE,
Tokens.IN,
Tokens.ISA,
Tokens.WHERE,
Tokens.TRUE,
Tokens.FALSE,
]

const kw_hash = Dict(simple_hash(lowercase(string(kw))) => kw for kw in kws)

end # module
