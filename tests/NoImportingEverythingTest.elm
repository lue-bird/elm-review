module NoImportingEverythingTest exposing (all)

import Elm.Syntax.Range exposing (Location, Range)
import Lint.Rule as Rule exposing (Error, Rule)
import Lint.Rule.NoImportingEverything exposing (Configuration, rule)
import Lint.Test exposing (LintResult)
import Lint.Test2
import Test exposing (Test, describe, test)


testRule : Configuration -> String -> LintResult
testRule options =
    Lint.Test.run (rule options)


error : String -> Error
error message =
    Lint.Test.errorWithoutRange message


tests : List Test
tests =
    [ test "should not report imports that do not expose anything" <|
        \() ->
            """module A exposing (..)
import Html
import Http
"""
                |> testRule { exceptions = [] }
                |> Lint.Test.expectErrorsWithoutRange []
    , test "should not report imports that expose functions by name" <|
        \() ->
            """module A exposing (..)
import Html exposing (a)
import Http exposing (a, b)
"""
                |> testRule { exceptions = [] }
                |> Lint.Test.expectErrorsWithoutRange []
    , test "should report imports that expose everything" <|
        \() ->
            """module A exposing (..)
import Html exposing (..)
"""
                |> testRule { exceptions = [] }
                |> Lint.Test.expectErrorsWithoutRange
                    [ error "Do not expose everything from Html" ]
    , test "should report imports from sub-modules" <|
        \() ->
            """module A exposing (..)
import Html.App exposing (..)
"""
                |> testRule { exceptions = [] }
                |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html.App" ]
    , test "should report imports from sub-modules (multiple dots)" <|
        \() ->
            """module A exposing (..)
import Html.Foo.Bar exposing (..)
"""
                |> testRule { exceptions = [] }
                |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html.Foo.Bar" ]
    , test "should not report imports that expose everything that are in the exception list" <|
        \() ->
            """module A exposing (..)
import Html exposing (..)
"""
                |> testRule { exceptions = [ "Html" ] }
                |> Lint.Test.expectErrorsWithoutRange []
    , test "should not report imports from sub-modules that are in the exception list" <|
        \() ->
            """module A exposing (..)
import Html.App exposing (..)
"""
                |> testRule { exceptions = [ "Html.App" ] }
                |> Lint.Test.expectErrorsWithoutRange []
    , test "should not report imports from sub-modules (multiple dots)" <|
        \() ->
            """module A exposing (..)
import Html.Foo.Bar exposing (..)
"""
                |> testRule { exceptions = [ "Html.Foo.Bar" ] }
                |> Lint.Test.expectErrorsWithoutRange []
    , test "should report imports whose parent is ignored" <|
        \() ->
            """module A exposing (..)
import Html.Foo.Bar exposing (..)
"""
                |> testRule { exceptions = [ "Html" ] }
                |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html.Foo.Bar" ]
    , test "should report imports whose sub-module is ignored" <|
        \() ->
            """module A exposing (..)
import Html exposing (..)
"""
                |> testRule { exceptions = [ "Html.App" ] }
                |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html" ]
    ]


testRule2 : Configuration -> String -> Lint.Test2.LintResult
testRule2 options =
    Lint.Test2.run (rule options)


tests2 : List Test
tests2 =
    [ test "A-should not report imports that do not expose anything" <|
        \() ->
            """module A exposing (..)
import Html
import Http
"""
                |> testRule2 { exceptions = [] }
                |> Lint.Test2.expectNoErrors
    , test "A-should not report imports that expose functions by name" <|
        \() ->
            """module A exposing (..)
import Html exposing (a)
import Http exposing (a, b)"""
                |> testRule2 { exceptions = [] }
                |> Lint.Test2.expectNoErrors
    , test "A-should report imports that expose everything" <|
        \() ->
            """module A exposing (..)
import Html exposing
  (..)"""
                |> testRule2 { exceptions = [] }
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error "Do not expose everything from Html"
                        |> Lint.Test2.under "(..)"
                    ]

    -- [ error "Do not expose everything from Html" ]
    --     , test "A-should report imports from sub-modules" <|
    --         \() ->
    --             """module A exposing (..)
    -- import Html.App exposing (..)
    -- """
    --                 |> testRule { exceptions = [] }
    --                 |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html.App" ]
    --     , test "A-should report imports from sub-modules (multiple dots)" <|
    --         \() ->
    --             """module A exposing (..)
    -- import Html.Foo.Bar exposing (..)
    -- """
    --                 |> testRule { exceptions = [] }
    --                 |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html.Foo.Bar" ]
    --     , test "A-should not report imports that expose everything that are in the exception list" <|
    --         \() ->
    --             """module A exposing (..)
    -- import Html exposing (..)
    -- """
    --                 |> testRule { exceptions = [ "Html" ] }
    --                 |> Lint.Test.expectErrorsWithoutRange []
    --     , test "A-should not report imports from sub-modules that are in the exception list" <|
    --         \() ->
    --             """module A exposing (..)
    -- import Html.App exposing (..)
    -- """
    --                 |> testRule { exceptions = [ "Html.App" ] }
    --                 |> Lint.Test.expectErrorsWithoutRange []
    --     , test "A-should not report imports from sub-modules (multiple dots)" <|
    --         \() ->
    --             """module A exposing (..)
    -- import Html.Foo.Bar exposing (..)
    -- """
    --                 |> testRule { exceptions = [ "Html.Foo.Bar" ] }
    --                 |> Lint.Test.expectErrorsWithoutRange []
    --     , test "A-should report imports whose parent is ignored" <|
    --         \() ->
    --             """module A exposing (..)
    -- import Html.Foo.Bar exposing (..)
    -- """
    --                 |> testRule { exceptions = [ "Html" ] }
    --                 |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html.Foo.Bar" ]
    --     , test "A-should report imports whose sub-module is ignored" <|
    --         \() ->
    --             """module A exposing (..)
    -- import Html exposing (..)
    -- """
    --                 |> testRule { exceptions = [ "Html.App" ] }
    --                 |> Lint.Test.expectErrorsWithoutRange [ error "Do not expose everything from Html" ]
    ]


all : Test
all =
    describe "NoImportingEverything" (tests ++ tests2)
