module Review.FixAll exposing (..)

import Dict exposing (Dict)
import Expect
import Json.Encode
import NoUnused.Variables
import Review.Error exposing (ReviewError(..), Target(..))
import Review.Fix.Internal exposing (Fix(..))
import Review.Options
import Review.Project as Project exposing (Project)
import Review.Rule as Rule
import Test exposing (Test, describe, test)


all : Test
all =
    describe "Fix all"
        [ test "should not touch the project when fixes are disabled" <|
            \() ->
                let
                    project : Project
                    project =
                        Project.new
                            |> Project.addModule
                                { path = "A.elm"
                                , source = """
module A exposing (a)
a = 1
b = 1
"""
                                }
                in
                Review.Options.withFixes Review.Options.fixedDisabled
                    |> runWithOptions project
                    |> .project
                    |> Project.modules
                    |> Expect.equal (Project.modules project)
        , test "should touch the project when running with fixes enabled without limit" <|
            \() ->
                let
                    project : Project
                    project =
                        Project.new
                            |> Project.addModule
                                { path = "A.elm"
                                , source = """
module A exposing (a)
a = 1
b = 1
c = 1
"""
                                }

                    expectedProjectModules : List Project.ProjectModule
                    expectedProjectModules =
                        Project.new
                            |> Project.addModule
                                { path = "A.elm"
                                , source = """
module A exposing (a)
a = 1
"""
                                }
                            |> Project.modules

                    results : { errors : List Rule.ReviewError, fixedErrors : Dict String (List Rule.ReviewError), rules : List Rule.Rule, project : Project, extracts : Dict String Json.Encode.Value }
                    results =
                        Review.Options.withFixes Review.Options.fixesEnabledWithoutLimits
                            |> runWithOptions project
                in
                Expect.all
                    [ \() ->
                        results.fixedErrors
                            |> Expect.equal
                                (Dict.fromList
                                    [ ( "A.elm"
                                      , [ ReviewError
                                            { message = "Top-level variable `c` is not used"
                                            , details = [ "You should either use this value somewhere, or remove it at the location I pointed at." ]
                                            , filePath = "A.elm"
                                            , fixes = Just [ Removal { end = { column = 1, row = 5 }, start = { column = 1, row = 4 } } ]
                                            , preventsExtract = False
                                            , range = { end = { column = 2, row = 4 }, start = { column = 1, row = 4 } }
                                            , ruleName = "NoUnused.Variables"
                                            , target = Module
                                            }
                                        , ReviewError
                                            { message = "Top-level variable `b` is not used"
                                            , details = [ "You should either use this value somewhere, or remove it at the location I pointed at." ]
                                            , filePath = "A.elm"
                                            , fixes = Just [ Removal { end = { column = 1, row = 5 }, start = { column = 1, row = 4 } } ]
                                            , preventsExtract = False
                                            , range = { end = { column = 2, row = 4 }, start = { column = 1, row = 4 } }
                                            , ruleName = "NoUnused.Variables"
                                            , target = Module
                                            }
                                        ]
                                      )
                                    ]
                                )
                    , \() ->
                        Project.modules results.project
                            |> Expect.equal expectedProjectModules
                    ]
                    ()
        ]


runWithOptions :
    Project
    -> (Review.Options.ReviewOptions -> Review.Options.ReviewOptions)
    -> { errors : List Rule.ReviewError, fixedErrors : Dict String (List Rule.ReviewError), rules : List Rule.Rule, project : Project, extracts : Dict String Json.Encode.Value }
runWithOptions project buildOptions =
    Rule.reviewV3 (buildOptions Review.Options.defaults)
        [ NoUnused.Variables.rule ]
        project
