module Review.Cli exposing (program, Program, ProgramEvent(..), ProgramState(..))

{-| Run reviews from the terminal, re-running on file changes

@docs program, Program, ProgramEvent, ProgramState

If you experience a high memory footprint in a large project,
please open an issue called "only ask for file sources to generate local error displays"

-}

import Ansi
import Array exposing (Array)
import Elm.Docs
import Elm.Parser
import Elm.Project
import Elm.Syntax.File
import Elm.Syntax.Range
import FastDict
import FastDictExtra
import Json.Decode
import Json.Encode
import Review exposing (Review)


{-| An elm worker produced by [`Review.Cli.Program`](Review-Cli#Program)
-}
type alias Program =
    Platform.Program () ProgramState ProgramEvent


{-| elm model of a [`Review.program`](#program)
-}
type ProgramState
    = WaitingForInitialFiles
    | HavingRunReviewsPreviously
        { nextRuns : List Review.Run
        , availableErrorsOnReject :
            FastDict.Dict
                String
                (List
                    { range : Elm.Syntax.Range.Range
                    , message : String
                    , details : List String
                    , fix : List Review.Fix
                    }
                )
        , elmJson : { source : String, project : Elm.Project.Project }
        , filesByPath : FastDict.Dict String String
        }


{-| elm msg of a [`Review.Cli.program`](#program)
-}
type ProgramEvent
    = InitialFilesReceived
        { elmJson : { source : String, project : Elm.Project.Project }
        , directDependencies : List { elmJson : Elm.Project.Project, docsJson : List Elm.Docs.Module }
        , extraFiles : List { path : String, source : String }
        , modules : List { path : String, source : String, syntax : Elm.Syntax.File.File }
        }
    | ModuleAddedOrChanged { path : String, source : String, syntax : Elm.Syntax.File.File }
    | ModuleRemoved { path : String }
    | ExtraFileAddedOrChanged { path : String, source : String }
    | ExtraFileRemoved { path : String }
    | ErrorFixRejected
    | JsonDecodingFailed Json.Decode.Error


type alias ProjectFileError =
    { range : Elm.Syntax.Range.Range
    , message : String
    , details : List String
    , fix : List Review.Fix
    }


{-| A node.js CLI program.
Start initializing one as showcased in [elm-review-mini-cli-starter](https://github.com/lue-bird/elm-review-mini-cli-starter)
-}
program :
    { toJs : Json.Encode.Value -> Cmd Never
    , fromJs : (Json.Encode.Value -> ProgramEvent) -> Sub ProgramEvent
    , configuration : { reviews : List Review.Review, extraPaths : List String }
    }
    -> Program
program config =
    Platform.worker
        { init = \() -> initialStateAndCommand config
        , update =
            \event state -> state |> reactToEvent config event
        , subscriptions = \state -> state |> listen config
        }


initialStateAndCommand :
    { toJs : Json.Encode.Value -> Cmd Never
    , fromJs : (Json.Encode.Value -> ProgramEvent) -> Sub ProgramEvent
    , configuration : { reviews : List Review.Review, extraPaths : List String }
    }
    -> ( ProgramState, Cmd never_ )
initialStateAndCommand config =
    ( WaitingForInitialFiles
    , Json.Encode.object
        [ ( "tag", "InitialFilesRequested" |> Json.Encode.string )
        , ( "value"
          , Json.Encode.object
                [ ( "extraPaths", config.configuration.extraPaths |> Json.Encode.list Json.Encode.string ) ]
          )
        ]
        |> config.toJs
        |> Cmd.map Basics.never
    )


reactToEvent :
    { toJs : Json.Encode.Value -> Cmd Never
    , fromJs : (Json.Encode.Value -> ProgramEvent) -> Sub ProgramEvent
    , configuration : { reviews : List Review.Review, extraPaths : List String }
    }
    -> ProgramEvent
    -> (ProgramState -> ( ProgramState, Cmd never_ ))
reactToEvent config event =
    \state ->
        case event of
            InitialFilesReceived initialFiles ->
                let
                    initialFilesByPath : FastDict.Dict String String
                    initialFilesByPath =
                        FastDict.union
                            (initialFiles.extraFiles
                                |> FastDictExtra.fromListMap (\file -> { key = file.path, value = file.source })
                            )
                            (initialFiles.modules
                                |> FastDictExtra.fromListMap (\file -> { key = file.path, value = file.source })
                            )

                    runResult :
                        { errorsByPath : FastDict.Dict String (List ProjectFileError)
                        , nextRuns : List Review.Run
                        }
                    runResult =
                        { addedOrChangedModules = initialFiles.modules
                        , addedOrChangedExtraFiles = initialFiles.extraFiles
                        , directDependencies = initialFiles.directDependencies
                        , elmJson = initialFiles.elmJson
                        , removedExtraFilePaths = []
                        , removedModulePaths = []
                        }
                            |> reviewRunList config.configuration.reviews

                    maybeNextFixableErrorOrAllUnfixable : Maybe NextFixableOrAllUnfixable
                    maybeNextFixableErrorOrAllUnfixable =
                        runResult.errorsByPath
                            |> errorsByPathToNextFixableErrorOrAll
                                { elmJsonSource = initialFiles.elmJson.source
                                , filesByPath = initialFilesByPath
                                }
                in
                ( HavingRunReviewsPreviously
                    { nextRuns = runResult.nextRuns
                    , availableErrorsOnReject =
                        case maybeNextFixableErrorOrAllUnfixable of
                            Nothing ->
                                FastDict.empty

                            Just (AllUnfixable _) ->
                                FastDict.empty

                            Just (Fixable nextFixable) ->
                                nextFixable.otherErrors
                    , elmJson = initialFiles.elmJson
                    , filesByPath = initialFilesByPath
                    }
                , case maybeNextFixableErrorOrAllUnfixable of
                    Nothing ->
                        Cmd.none

                    Just nextFixableErrorOrAllUnfixable ->
                        nextFixableErrorOrAllUnfixable
                            |> errorReceivedToJson
                                { elmJsonSource = initialFiles.elmJson.source
                                , filesByPath = initialFilesByPath
                                }
                            |> config.toJs
                            |> Cmd.map Basics.never
                )

            ErrorFixRejected ->
                case state of
                    HavingRunReviewsPreviously havingRunReviewsPreviously ->
                        let
                            maybeNextFixableErrorOrAllUnfixable : Maybe NextFixableOrAllUnfixable
                            maybeNextFixableErrorOrAllUnfixable =
                                havingRunReviewsPreviously.availableErrorsOnReject
                                    |> errorsByPathToNextFixableErrorOrAll
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = havingRunReviewsPreviously.filesByPath
                                        }
                        in
                        ( HavingRunReviewsPreviously
                            { havingRunReviewsPreviously
                                | availableErrorsOnReject =
                                    case maybeNextFixableErrorOrAllUnfixable of
                                        Nothing ->
                                            FastDict.empty

                                        Just (AllUnfixable _) ->
                                            FastDict.empty

                                        Just (Fixable nextFixable) ->
                                            nextFixable.otherErrors
                            }
                        , case maybeNextFixableErrorOrAllUnfixable of
                            Nothing ->
                                Cmd.none

                            Just nextFixableErrorOrAllUnfixable ->
                                nextFixableErrorOrAllUnfixable
                                    |> errorReceivedToJson
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = havingRunReviewsPreviously.filesByPath
                                        }
                                    |> config.toJs
                                    |> Cmd.map Basics.never
                        )

                    unexpectedState ->
                        ( unexpectedState, Cmd.none )

            ModuleAddedOrChanged moduleAddedOrChanged ->
                case state of
                    HavingRunReviewsPreviously havingRunReviewsPreviously ->
                        let
                            filesByPathWithAddedOrChanged : FastDict.Dict String String
                            filesByPathWithAddedOrChanged =
                                havingRunReviewsPreviously.filesByPath
                                    |> FastDict.insert moduleAddedOrChanged.path moduleAddedOrChanged.source

                            runResult :
                                { errorsByPath : FastDict.Dict String (List ProjectFileError)
                                , nextRuns : List Review.Run
                                }
                            runResult =
                                { addedOrChangedExtraFiles = []
                                , addedOrChangedModules = [ moduleAddedOrChanged ]
                                , directDependencies = []
                                , elmJson = havingRunReviewsPreviously.elmJson
                                , removedExtraFilePaths = []
                                , removedModulePaths = []
                                }
                                    |> reviewRunList
                                        (List.map2
                                            (\review nextRun ->
                                                { ignoreErrorsForPathsWhere = review.ignoreErrorsForPathsWhere
                                                , run = nextRun
                                                }
                                            )
                                            config.configuration.reviews
                                            havingRunReviewsPreviously.nextRuns
                                        )

                            maybeNextFixableErrorOrAllUnfixable : Maybe NextFixableOrAllUnfixable
                            maybeNextFixableErrorOrAllUnfixable =
                                runResult.errorsByPath
                                    |> errorsByPathToNextFixableErrorOrAll
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithAddedOrChanged
                                        }
                        in
                        ( HavingRunReviewsPreviously
                            { nextRuns = runResult.nextRuns
                            , availableErrorsOnReject =
                                case maybeNextFixableErrorOrAllUnfixable of
                                    Nothing ->
                                        FastDict.empty

                                    Just (AllUnfixable _) ->
                                        FastDict.empty

                                    Just (Fixable nextFixable) ->
                                        nextFixable.otherErrors
                            , elmJson = havingRunReviewsPreviously.elmJson
                            , filesByPath = filesByPathWithAddedOrChanged
                            }
                        , case maybeNextFixableErrorOrAllUnfixable of
                            Nothing ->
                                Cmd.none

                            Just nextFixableErrorOrAllUnfixable ->
                                nextFixableErrorOrAllUnfixable
                                    |> errorReceivedToJson
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithAddedOrChanged
                                        }
                                    |> config.toJs
                                    |> Cmd.map Basics.never
                        )

                    unexpectedState ->
                        ( unexpectedState, Cmd.none )

            ModuleRemoved moduleRemoved ->
                case state of
                    HavingRunReviewsPreviously havingRunReviewsPreviously ->
                        let
                            filesByPathWithRemoved : FastDict.Dict String String
                            filesByPathWithRemoved =
                                havingRunReviewsPreviously.filesByPath
                                    |> FastDict.remove moduleRemoved.path

                            runResult :
                                { errorsByPath : FastDict.Dict String (List ProjectFileError)
                                , nextRuns : List Review.Run
                                }
                            runResult =
                                { addedOrChangedExtraFiles = []
                                , addedOrChangedModules = []
                                , directDependencies = []
                                , elmJson = havingRunReviewsPreviously.elmJson
                                , removedExtraFilePaths = []
                                , removedModulePaths = [ moduleRemoved.path ]
                                }
                                    |> reviewRunList
                                        (List.map2
                                            (\review nextRun ->
                                                { ignoreErrorsForPathsWhere = review.ignoreErrorsForPathsWhere
                                                , run = nextRun
                                                }
                                            )
                                            config.configuration.reviews
                                            havingRunReviewsPreviously.nextRuns
                                        )

                            maybeNextFixableErrorOrAllUnfixable : Maybe NextFixableOrAllUnfixable
                            maybeNextFixableErrorOrAllUnfixable =
                                runResult.errorsByPath
                                    |> errorsByPathToNextFixableErrorOrAll
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithRemoved
                                        }
                        in
                        ( HavingRunReviewsPreviously
                            { nextRuns = runResult.nextRuns
                            , availableErrorsOnReject =
                                case maybeNextFixableErrorOrAllUnfixable of
                                    Nothing ->
                                        FastDict.empty

                                    Just (AllUnfixable _) ->
                                        FastDict.empty

                                    Just (Fixable nextFixable) ->
                                        nextFixable.otherErrors
                            , elmJson = havingRunReviewsPreviously.elmJson
                            , filesByPath = filesByPathWithRemoved
                            }
                        , case maybeNextFixableErrorOrAllUnfixable of
                            Nothing ->
                                Cmd.none

                            Just nextFixableErrorOrAllUnfixable ->
                                nextFixableErrorOrAllUnfixable
                                    |> errorReceivedToJson
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithRemoved
                                        }
                                    |> config.toJs
                                    |> Cmd.map Basics.never
                        )

                    unexpectedState ->
                        ( unexpectedState, Cmd.none )

            ExtraFileAddedOrChanged fileAddedOrChanged ->
                case state of
                    HavingRunReviewsPreviously havingRunReviewsPreviously ->
                        let
                            filesByPathWithAddedOrChanged : FastDict.Dict String String
                            filesByPathWithAddedOrChanged =
                                havingRunReviewsPreviously.filesByPath
                                    |> FastDict.insert fileAddedOrChanged.path fileAddedOrChanged.source

                            runResult :
                                { errorsByPath : FastDict.Dict String (List ProjectFileError)
                                , nextRuns : List Review.Run
                                }
                            runResult =
                                { addedOrChangedExtraFiles = [ fileAddedOrChanged ]
                                , addedOrChangedModules = []
                                , directDependencies = []
                                , elmJson = havingRunReviewsPreviously.elmJson
                                , removedExtraFilePaths = []
                                , removedModulePaths = []
                                }
                                    |> reviewRunList
                                        (List.map2
                                            (\review nextRun ->
                                                { ignoreErrorsForPathsWhere = review.ignoreErrorsForPathsWhere
                                                , run = nextRun
                                                }
                                            )
                                            config.configuration.reviews
                                            havingRunReviewsPreviously.nextRuns
                                        )

                            maybeNextFixableErrorOrAllUnfixable : Maybe NextFixableOrAllUnfixable
                            maybeNextFixableErrorOrAllUnfixable =
                                runResult.errorsByPath
                                    |> errorsByPathToNextFixableErrorOrAll
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithAddedOrChanged
                                        }
                        in
                        ( HavingRunReviewsPreviously
                            { nextRuns = runResult.nextRuns
                            , availableErrorsOnReject =
                                case maybeNextFixableErrorOrAllUnfixable of
                                    Nothing ->
                                        FastDict.empty

                                    Just (AllUnfixable _) ->
                                        FastDict.empty

                                    Just (Fixable nextFixable) ->
                                        nextFixable.otherErrors
                            , elmJson = havingRunReviewsPreviously.elmJson
                            , filesByPath = filesByPathWithAddedOrChanged
                            }
                        , case maybeNextFixableErrorOrAllUnfixable of
                            Nothing ->
                                Cmd.none

                            Just nextFixableErrorOrAllUnfixable ->
                                nextFixableErrorOrAllUnfixable
                                    |> errorReceivedToJson
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithAddedOrChanged
                                        }
                                    |> config.toJs
                                    |> Cmd.map Basics.never
                        )

                    unexpectedState ->
                        ( unexpectedState, Cmd.none )

            ExtraFileRemoved fileRemoved ->
                case state of
                    HavingRunReviewsPreviously havingRunReviewsPreviously ->
                        let
                            filesByPathWithRemoved : FastDict.Dict String String
                            filesByPathWithRemoved =
                                havingRunReviewsPreviously.filesByPath
                                    |> FastDict.remove fileRemoved.path

                            runResult :
                                { errorsByPath : FastDict.Dict String (List ProjectFileError)
                                , nextRuns : List Review.Run
                                }
                            runResult =
                                { addedOrChangedExtraFiles = []
                                , addedOrChangedModules = []
                                , directDependencies = []
                                , elmJson = havingRunReviewsPreviously.elmJson
                                , removedExtraFilePaths = [ fileRemoved.path ]
                                , removedModulePaths = []
                                }
                                    |> reviewRunList
                                        (List.map2
                                            (\review nextRun ->
                                                { ignoreErrorsForPathsWhere = review.ignoreErrorsForPathsWhere
                                                , run = nextRun
                                                }
                                            )
                                            config.configuration.reviews
                                            havingRunReviewsPreviously.nextRuns
                                        )

                            maybeNextFixableErrorOrAllUnfixable : Maybe NextFixableOrAllUnfixable
                            maybeNextFixableErrorOrAllUnfixable =
                                runResult.errorsByPath
                                    |> errorsByPathToNextFixableErrorOrAll
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithRemoved
                                        }
                        in
                        ( HavingRunReviewsPreviously
                            { nextRuns = runResult.nextRuns
                            , availableErrorsOnReject =
                                case maybeNextFixableErrorOrAllUnfixable of
                                    Nothing ->
                                        FastDict.empty

                                    Just (AllUnfixable _) ->
                                        FastDict.empty

                                    Just (Fixable nextFixable) ->
                                        nextFixable.otherErrors
                            , elmJson = havingRunReviewsPreviously.elmJson
                            , filesByPath = filesByPathWithRemoved
                            }
                        , case maybeNextFixableErrorOrAllUnfixable of
                            Nothing ->
                                Cmd.none

                            Just nextFixableErrorOrAllUnfixable ->
                                nextFixableErrorOrAllUnfixable
                                    |> errorReceivedToJson
                                        { elmJsonSource = havingRunReviewsPreviously.elmJson.source
                                        , filesByPath = filesByPathWithRemoved
                                        }
                                    |> config.toJs
                                    |> Cmd.map Basics.never
                        )

                    unexpectedState ->
                        ( unexpectedState, Cmd.none )

            JsonDecodingFailed decodeError ->
                ( state
                , Json.Encode.object
                    [ ( "tag", "JsonDecodingFailed" |> Json.Encode.string )
                    , ( "value", decodeError |> Json.Decode.errorToString |> Json.Encode.string )
                    ]
                    |> config.toJs
                    |> Cmd.map Basics.never
                )


reviewRunList :
    List Review
    ->
        { elmJson : { source : String, project : Elm.Project.Project }
        , directDependencies : List { elmJson : Elm.Project.Project, docsJson : List Elm.Docs.Module }
        , addedOrChangedExtraFiles : List { path : String, source : String }
        , addedOrChangedModules : List { path : String, source : String, syntax : Elm.Syntax.File.File }
        , removedExtraFilePaths : List String
        , removedModulePaths : List String
        }
    ->
        { errorsByPath : FastDict.Dict String (List ProjectFileError)
        , nextRuns : List Review.Run
        }
reviewRunList reviews project =
    let
        runResultsForReviews :
            List
                { errorsByPath : FastDict.Dict String (List ProjectFileError)
                , nextRun : Review.Run
                }
        runResultsForReviews =
            reviews |> List.map (\review -> project |> Review.run review)
    in
    { errorsByPath =
        runResultsForReviews
            |> List.foldl
                (\runResultForReview soFar ->
                    FastDictExtra.unionWith (\new already -> new ++ already)
                        runResultForReview.errorsByPath
                        soFar
                )
                FastDict.empty
    , nextRuns = runResultsForReviews |> List.map .nextRun
    }


errorsByPathToNextFixableErrorOrAll :
    { elmJsonSource : String, filesByPath : FastDict.Dict String String }
    -> FastDict.Dict String (List ProjectFileError)
    -> Maybe NextFixableOrAllUnfixable
errorsByPathToNextFixableErrorOrAll project =
    \errorsByPath ->
        let
            nextFixableErrorOrAll :
                { fixable :
                    Maybe
                        { source : String
                        , fixedSource : String
                        , message : String
                        , details : List String
                        , range : Elm.Syntax.Range.Range
                        , path : String
                        }
                , otherErrors : FastDict.Dict String (List ProjectFileError)
                }
            nextFixableErrorOrAll =
                errorsByPath
                    |> FastDict.foldl
                        (\path errors soFar ->
                            let
                                errorsFixableErrorOrAll :
                                    { fixable :
                                        Maybe
                                            { source : String
                                            , fixedSource : String
                                            , message : String
                                            , details : List String
                                            , range : Elm.Syntax.Range.Range
                                            , path : String
                                            }
                                    , otherErrors : List ProjectFileError
                                    }
                                errorsFixableErrorOrAll =
                                    case soFar.fixable of
                                        Just soFarFix ->
                                            { fixable = soFarFix |> Just
                                            , otherErrors = errors
                                            }

                                        Nothing ->
                                            let
                                                maybeSourceToFix : Maybe String
                                                maybeSourceToFix =
                                                    case path of
                                                        "elmJson" ->
                                                            project.elmJsonSource |> Just

                                                        filePath ->
                                                            project.filesByPath |> FastDict.get filePath
                                            in
                                            case maybeSourceToFix of
                                                Nothing ->
                                                    { fixable = Nothing
                                                    , otherErrors = errors
                                                    }

                                                Just sourceToFix ->
                                                    errors
                                                        |> List.foldl
                                                            (\error errorsResultSoFar ->
                                                                case error.fix of
                                                                    [] ->
                                                                        { fixable = Nothing
                                                                        , otherErrors = errorsResultSoFar.otherErrors |> (::) error
                                                                        }

                                                                    fix0 :: fix1Up ->
                                                                        case sourceToFix |> Review.applyFix (fix0 :: fix1Up) of
                                                                            Ok fixedSource ->
                                                                                { fixable = { source = sourceToFix, fixedSource = fixedSource, message = error.message, details = error.details, range = error.range, path = path } |> Just
                                                                                , otherErrors = errorsResultSoFar.otherErrors |> (::) error
                                                                                }

                                                                            Err _ ->
                                                                                { fixable = Nothing
                                                                                , otherErrors = errorsResultSoFar.otherErrors |> (::) error
                                                                                }
                                                            )
                                                            { fixable = Nothing
                                                            , otherErrors = []
                                                            }
                            in
                            { fixable = errorsFixableErrorOrAll.fixable
                            , otherErrors = soFar.otherErrors |> FastDict.insert path errorsFixableErrorOrAll.otherErrors
                            }
                        )
                        { fixable = Nothing
                        , otherErrors = FastDict.empty
                        }
        in
        case ( nextFixableErrorOrAll.fixable, nextFixableErrorOrAll.otherErrors |> FastDictExtra.all (\_ errors -> errors |> List.isEmpty) ) of
            ( Nothing, True ) ->
                Nothing

            ( Just fixable, _ ) ->
                Fixable { fixable = fixable, otherErrors = nextFixableErrorOrAll.otherErrors }
                    |> Just

            ( Nothing, False ) ->
                AllUnfixable nextFixableErrorOrAll.otherErrors
                    |> Just


errorReceivedToJson :
    { elmJsonSource : String, filesByPath : FastDict.Dict String String }
    -> NextFixableOrAllUnfixable
    -> Json.Encode.Value
errorReceivedToJson projectSources =
    \nextFixableOrAllUnfixable ->
        Json.Encode.object
            [ ( "tag", "ErrorsReceived" |> Json.Encode.string )
            , ( "value"
              , case nextFixableOrAllUnfixable of
                    AllUnfixable allUnfixable ->
                        Json.Encode.object
                            [ ( "display"
                              , allUnfixable
                                    |> FastDictExtra.concatToListMap
                                        (\path errors ->
                                            let
                                                pathSource : String
                                                pathSource =
                                                    case path of
                                                        "elm.json" ->
                                                            projectSources.elmJsonSource

                                                        filePath ->
                                                            projectSources.filesByPath |> FastDict.get filePath |> Maybe.withDefault ""
                                            in
                                            errors
                                                |> List.map
                                                    (\error ->
                                                        { path = path
                                                        , range = error.range
                                                        , message = error.message
                                                        , details = error.details
                                                        , fix = error.fix
                                                        }
                                                            |> errorDisplay pathSource
                                                    )
                                        )
                                    |> String.join "\n\n\n"
                                    |> Json.Encode.string
                              )
                            , ( "fix", Json.Encode.null )
                            ]

                    Fixable fixable ->
                        Json.Encode.object
                            [ ( "display", fixable.fixable |> errorDisplay fixable.fixable.source |> Json.Encode.string )
                            , ( "fix"
                              , Json.Encode.object
                                    [ ( "path", fixable.fixable.path |> Json.Encode.string )
                                    , ( "fixedSource", fixable.fixable.fixedSource |> Json.Encode.string )
                                    ]
                              )
                            ]
              )
            ]


errorDisplay : String -> { error_ | path : String, range : Elm.Syntax.Range.Range, message : String, details : List String } -> String
errorDisplay source =
    \error ->
        [ error.path
        , ":"
        , error.range.start.row |> String.fromInt
        , ":"
        , error.range.start.column |> String.fromInt
        , "\n\n    "
        , error.message
        , "\n\n"
        , codeExtract source error.range
            |> String.split "\n"
            |> List.map (\line -> "|   " ++ line)
            |> String.join "\n"
        , "\n\n"
        , error.details |> String.join "\n\n"
        ]
            |> String.concat


getIndexOfFirstNonSpace : String -> Int
getIndexOfFirstNonSpace string =
    (string |> String.length) - (string |> String.trimLeft |> String.length)


codeExtract : String -> Elm.Syntax.Range.Range -> String
codeExtract source range =
    let
        sourceLines : Array String
        sourceLines =
            source |> String.lines |> Array.fromList

        sourceLineAtRow : Int -> String
        sourceLineAtRow rowIndex =
            case sourceLines |> Array.get rowIndex of
                Just line ->
                    line |> String.trimRight

                Nothing ->
                    ""
    in
    if range.start.row == range.end.row then
        if range.start.column == range.end.column then
            ""

        else
            let
                lineContent : String
                lineContent =
                    sourceLineAtRow (range.start.row - 1)
            in
            [ sourceLineAtRow (range.start.row - 2)
            , lineContent
            , errorRangeUnderline { start = range.start.column, end = range.end.column, lineContent = lineContent }
            , sourceLineAtRow range.end.row
            ]
                |> List.filter (\l -> not (l |> String.isEmpty))
                |> String.join "\n"

    else
        let
            startLineNumber : Int
            startLineNumber =
                range.start.row - 1

            startLineContent : String
            startLineContent =
                sourceLineAtRow startLineNumber

            linesBetweenStartAndEnd : List Int
            linesBetweenStartAndEnd =
                List.range range.start.row (range.end.row - 2)

            endLineContent : String
            endLineContent =
                sourceLineAtRow (range.end.row - 1)
        in
        [ [ sourceLineAtRow (startLineNumber - 1)
          , startLineContent
          , errorRangeUnderline
                { start = range.start.column
                , end = List.length (String.toList startLineContent) + 1
                , lineContent = startLineContent
                }
          ]
            |> List.filter (\l -> not (l |> String.isEmpty))
            |> String.join "\n"
        , linesBetweenStartAndEnd
            |> List.map
                (\middleLine ->
                    let
                        line : String
                        line =
                            sourceLineAtRow middleLine
                    in
                    if String.isEmpty line then
                        sourceLineAtRow middleLine

                    else
                        [ sourceLineAtRow middleLine
                        , "\n"
                        , errorUnderlineWholeLine line
                        ]
                            |> String.concat
                )
            |> String.join "\n"
        , [ endLineContent
          , errorRangeUnderline
                { start = getIndexOfFirstNonSpace endLineContent + 1
                , end = range.end.column
                , lineContent = endLineContent
                }
          , sourceLineAtRow range.end.row
          ]
            |> List.filter (\l -> not (l |> String.isEmpty))
            |> String.join "\n"
        ]
            |> String.join "\n"


errorUnderlineWholeLine : String -> String
errorUnderlineWholeLine line =
    let
        start : Int
        start =
            getIndexOfFirstNonSpace line

        end : Int
        end =
            line |> String.length
    in
    String.repeat start " "
        ++ (String.repeat (end - start) "^" |> Ansi.red)


errorRangeUnderline : { start : Int, end : Int, lineContent : String } -> String
errorRangeUnderline toUnderline =
    let
        lineChars : List Char
        lineChars =
            String.toList toUnderline.lineContent

        preText : List Char
        preText =
            List.take (toUnderline.start - 1) lineChars

        unicodePreOffset : Int
        unicodePreOffset =
            String.length (String.fromList preText) - List.length preText

        inText : List Char
        inText =
            lineChars
                |> List.drop (toUnderline.start - 1)
                |> List.take (toUnderline.end - toUnderline.start)

        unicodeInOffset : Int
        unicodeInOffset =
            -- We want to show enough ^ characters to cover the whole underlined zone,
            -- and for unicode characters that sometimes means 2 ^
            String.length (String.fromList inText) - List.length inText
    in
    String.repeat (unicodePreOffset + toUnderline.start - 1) " "
        ++ (String.repeat (unicodeInOffset + toUnderline.end - toUnderline.start) "^" |> Ansi.red)


listen :
    { toJs : Json.Encode.Value -> Cmd Never
    , fromJs : (Json.Encode.Value -> ProgramEvent) -> Sub ProgramEvent
    , configuration : { reviews : List Review.Review, extraPaths : List String }
    }
    -> (ProgramState -> Sub ProgramEvent)
listen config =
    \_ ->
        config.fromJs
            (\fromJs ->
                case fromJs |> Json.Decode.decodeValue eventJsonDecoder of
                    Err decodeError ->
                        JsonDecodingFailed decodeError

                    Ok event ->
                        event
            )


eventJsonDecoder : Json.Decode.Decoder ProgramEvent
eventJsonDecoder =
    Json.Decode.field "tag" Json.Decode.string
        |> Json.Decode.andThen
            (\tag ->
                Json.Decode.field "value"
                    (case tag of
                        "InitialFilesReceived" ->
                            Json.Decode.map4
                                (\elmJson directDependencies modules extraFiles ->
                                    InitialFilesReceived
                                        { elmJson = elmJson
                                        , directDependencies = directDependencies
                                        , modules = modules
                                        , extraFiles = extraFiles
                                        }
                                )
                                (Json.Decode.field "elmJson"
                                    (Json.Decode.map2 (\source project -> { source = source, project = project })
                                        (Json.Decode.field "source" Json.Decode.string)
                                        (Json.Decode.field "project" Elm.Project.decoder)
                                    )
                                )
                                (Json.Decode.field "directDependencies"
                                    (Json.Decode.list
                                        (Json.Decode.map2
                                            (\elmJson docsJson -> { elmJson = elmJson, docsJson = docsJson })
                                            (Json.Decode.field "elmJson" Elm.Project.decoder)
                                            (Json.Decode.field "docsJson" (Json.Decode.list Elm.Docs.decoder))
                                        )
                                    )
                                )
                                (Json.Decode.field "modules"
                                    (Json.Decode.list moduleDataJsonDecoder)
                                )
                                (Json.Decode.field "extraFiles"
                                    (Json.Decode.list
                                        (Json.Decode.map2
                                            (\path source -> { path = path, source = source })
                                            (Json.Decode.field "path" Json.Decode.string)
                                            (Json.Decode.field "source" Json.Decode.string)
                                        )
                                    )
                                )

                        "ModuleAddedOrChanged" ->
                            Json.Decode.map ModuleAddedOrChanged moduleDataJsonDecoder

                        "ModuleRemoved" ->
                            Json.Decode.map
                                (\path -> ModuleRemoved { path = path })
                                (Json.Decode.field "path" Json.Decode.string)

                        "ExtraFileAddedOrChanged" ->
                            Json.Decode.map2
                                (\path source -> ExtraFileAddedOrChanged { path = path, source = source })
                                (Json.Decode.field "path" Json.Decode.string)
                                (Json.Decode.field "source" Json.Decode.string)

                        "ExtraFileRemoved" ->
                            Json.Decode.map
                                (\path -> ExtraFileRemoved { path = path })
                                (Json.Decode.field "path" Json.Decode.string)

                        "ErrorFixRejected" ->
                            Json.Decode.map (\() -> ErrorFixRejected)
                                (Json.Decode.null ())

                        unknownTag ->
                            Json.Decode.fail ("unknown js message tag " ++ unknownTag)
                    )
            )


moduleDataJsonDecoder : Json.Decode.Decoder { path : String, source : String, syntax : Elm.Syntax.File.File }
moduleDataJsonDecoder =
    Json.Decode.map2
        (\path source -> { path = path, source = source })
        (Json.Decode.field "path" Json.Decode.string)
        (Json.Decode.field "source" Json.Decode.string)
        |> Json.Decode.andThen
            (\moduleFile ->
                case moduleFile.source |> Elm.Parser.parseToFile of
                    Err _ ->
                        Json.Decode.fail "module parsing failed"

                    Ok syntax ->
                        { path = moduleFile.path, source = moduleFile.source, syntax = syntax }
                            |> Json.Decode.succeed
            )


type NextFixableOrAllUnfixable
    = AllUnfixable (FastDict.Dict String (List ProjectFileError))
    | Fixable
        { fixable :
            { source : String
            , fixedSource : String
            , message : String
            , details : List String
            , range : Elm.Syntax.Range.Range
            , path : String
            }
        , otherErrors : FastDict.Dict String (List ProjectFileError)
        }
