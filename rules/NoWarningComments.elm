module NoWarningComments exposing (rule)

import Ast.Statement exposing (..)
import Lint exposing (doNothing, lint)
import Regex exposing (Regex)
import Types exposing (Direction(..), Error, LintRule)


type alias Context =
    {}


rule : String -> List Error
rule input =
    lint input implementation


implementation : LintRule Context
implementation =
    { statementFn = statementFn
    , typeFn = doNothing
    , expressionFn = doNothing
    , moduleEndFn = (\ctx -> ( [], ctx ))
    , initialContext = Context
    }


error : String -> Error
error word =
    Error "NoWarningComments" ("Unexpected " ++ word ++ " comment")


commentRegex : Regex
commentRegex =
    Regex.caseInsensitive <| Regex.regex "(TODO|FIXME|XXX)"


findWarning : String -> Maybe Error
findWarning text =
    if String.contains "TODO" text then
        Just <| error "TODO"
    else if String.contains "todo" text then
        Just <| error "todo"
    else if String.contains "FIXME" text then
        Just <| error "FIXME"
    else if String.contains "fixme" text then
        Just <| error "fixme"
    else if String.contains "XXX" text then
        Just <| error "XXX"
    else if String.contains "xxx" text then
        Just <| error "xxx"
    else
        Nothing


statementFn : Context -> Direction Statement -> ( List Error, Context )
statementFn ctx node =
    case node of
        Enter (Comment text) ->
            let
                warning =
                    findWarning text
            in
                case warning of
                    Just err ->
                        ( [ err ], ctx )

                    Nothing ->
                        ( [], ctx )

        _ ->
            ( [], ctx )
