module SimplifyPiping exposing (rule)

import Lint exposing (lint, doNothing)
import Types exposing (LintRule, Error, Direction(..))
import Ast.Expression exposing (..)
import Set exposing (Set)


type alias Context =
    {}


rule : String -> List Error
rule input =
    lint input implementation


implementation : LintRule Context
implementation =
    { statementFn = doNothing
    , typeFn = doNothing
    , expressionFn = expressionFn
    , moduleEndFn = (\ctx -> ( [], ctx ))
    , initialContext = Context
    }


error : String -> String -> Error
error op fn =
    Error
        "SimplifyPiping"
        ("Instead of `" ++ fn ++ " f " ++ op ++ " List.map g`, try " ++ fn ++ " (f " ++ op ++ " g)")


simplifiableFns : Set String
simplifiableFns =
    Set.fromList
        [ "List.map"
        , "Set.map"
        , "Array.map"
        , "Array.indexedMap"
        ]


nameOfMethod : List (List String) -> String
nameOfMethod members =
    members
        |> List.concatMap (\a -> a)
        |> String.join "."


reportIfSimplifiableMethod : String -> Expression -> Expression -> List Error
reportIfSimplifiableMethod op left right =
    case [ left, right ] of
        [ Application (Access (Variable names1) fns1) _, Application (Access (Variable names2) fns2) _ ] ->
            if [ names1, fns1 ] == [ names2, fns2 ] && Set.member (nameOfMethod [ names1, fns1 ]) simplifiableFns then
                [ error op <| nameOfMethod [ names1, fns1 ] ]
            else
                []

        _ ->
            []


expressionFn : Context -> Direction Expression -> ( List Error, Context )
expressionFn ctx node =
    case node of
        Enter (BinOp (Variable [ "|>" ]) (Application left _) right) ->
            case right of
                -- X.y f data |> X.y g |> foo
                BinOp (Variable [ "|>" ]) subRight _ ->
                    ( reportIfSimplifiableMethod ">>" left subRight, ctx )

                -- X.y f data |> X.y g
                _ ->
                    ( reportIfSimplifiableMethod ">>" left right, ctx )

        -- X.y f <| X.y g data
        Enter (BinOp (Variable [ "<|" ]) left (Application right _)) ->
            case left of
                -- foo <| X.y f <| X.y g data
                BinOp (Variable [ "<|" ]) subLeft _ ->
                    ( reportIfSimplifiableMethod "<<" left subLeft, ctx )

                _ ->
                    ( reportIfSimplifiableMethod "<<" left right, ctx )

        -- a |> X.y f |> X.y g
        Enter (BinOp (Variable [ "|>" ]) _ (BinOp (Variable [ "|>" ]) left right)) ->
            ( reportIfSimplifiableMethod ">>" left right, ctx )

        -- X.y f <| X.y g <| a
        Enter (BinOp (Variable [ "<|" ]) left (BinOp (Variable [ "<|" ]) right _)) ->
            ( reportIfSimplifiableMethod "<<" left right, ctx )

        Enter (BinOp (Variable [ ">>" ]) left right) ->
            case left of
                -- foo >> X.y f >> X.y g
                BinOp (Variable [ ">>" ]) _ subLeft ->
                    ( reportIfSimplifiableMethod ">>" subLeft right, ctx )

                -- X.y f >> X.y g
                _ ->
                    ( reportIfSimplifiableMethod ">>" left right, ctx )

        Enter (BinOp (Variable [ "<<" ]) left right) ->
            case left of
                -- foo << X.y f << X.y g
                BinOp (Variable [ "<<" ]) _ subLeft ->
                    ( reportIfSimplifiableMethod "<<" subLeft right, ctx )

                -- X.y f << X.y g
                _ ->
                    ( reportIfSimplifiableMethod "<<" left right, ctx )

        _ ->
            ( [], ctx )
