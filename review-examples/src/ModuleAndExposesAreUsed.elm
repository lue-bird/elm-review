module ModuleAndExposesAreUsed exposing (review)

{-|

@docs review

-}

import Declaration.LocalExtra
import Elm.Project
import Elm.Syntax.Declaration
import Elm.Syntax.Exposing
import Elm.Syntax.File
import Elm.Syntax.Import
import Elm.Syntax.Module
import Elm.Syntax.ModuleName
import Elm.Syntax.Node
import Elm.Syntax.Range
import FastDict
import FastDict.LocalExtra
import Review  
import Set exposing (Set)


{-| Report exposed members of modules that aren't referenced outside of the module itself.
If there would be no exposed members left, report the whole module as unused.

Unused code might be a sign that someone wanted to use it for something but didn't do so, yet.
But maybe you've since moved in a different direction,
in which case allowing the unused code to sit can make it harder to find what's important.

If intended for determined future use, try gradually using it.
If intended as a very generic utility, try moving it into a package
(possibly local-only, using `Review.ignoreErrorsForPathsWhere (String.startsWith "your-local-package-source-directory")`).
If you think you don't need it anymore or think it was added it prematurely, you can remove it.


### reported

    module Main exposing (main)

    import A

    main =
        A.a

using

    import A exposing (a, unusedExpose)

    a =
        unusedExpose

    unusedExpose =
        ...


### not reported

    module Main exposing (main)

    import A

    main =
        A.a

using

    import A exposing (a)

    a =
        private

    private =
        ...

-}
review : Review.Review
review =
    Review.create
        { inspect =
            [ Review.inspectElmJson
                (\elmJson ->
                    { identifierUseCounts = FastDict.empty
                    , moduleExposes = FastDict.empty
                    , modulesAllowingUnusedExposes =
                        case elmJson.project of
                            Elm.Project.Application _ ->
                                Set.empty

                            Elm.Project.Package packageElmJson ->
                                packageElmJson.exposed |> Review.packageElmJsonExposedModules
                    , moduleImports = FastDict.empty
                    }
                )
            , Review.inspectModule
                moduleDataToKnowledge
            ]
        , knowledgeMerge = knowledgeMerge
        , report = report
        }


type alias Knowledge =
    { identifierUseCounts :
        FastDict.Dict
            Elm.Syntax.ModuleName.ModuleName
            { importsExposingAll : List { moduleName : Elm.Syntax.ModuleName.ModuleName, alias : Maybe String }
            , importsExposingExplicit :
                List
                    { moduleName : Elm.Syntax.ModuleName.ModuleName
                    , alias : Maybe String
                    , simpleNames : Set String
                    , typesExposingVariants : Set String
                    }
            , identifierUseCounts : FastDict.Dict ( Elm.Syntax.ModuleName.ModuleName, String ) Int
            }
    , modulesAllowingUnusedExposes : Set Elm.Syntax.ModuleName.ModuleName
    , moduleExposes :
        FastDict.Dict
            Elm.Syntax.ModuleName.ModuleName
            { path : String
            , exposingRange : Elm.Syntax.Range.Range
            , exposedSimpleNames : FastDict.Dict String Elm.Syntax.Range.Range
            , exposedTypesWithVariantNames : FastDict.Dict String { range : Elm.Syntax.Range.Range, variants : Set String }
            }
    , moduleImports :
        FastDict.Dict Elm.Syntax.ModuleName.ModuleName (List { path : String, row : Int })
    }


moduleDataToKnowledge :
    { moduleData_ | path : String, syntax : Elm.Syntax.File.File }
    -> Knowledge
moduleDataToKnowledge =
    \moduleData ->
        let
            moduleName : Elm.Syntax.ModuleName.ModuleName
            moduleName =
                moduleData.syntax.moduleDefinition |> Elm.Syntax.Node.value |> Elm.Syntax.Module.moduleName
        in
        { identifierUseCounts =
            { identifierUseCounts =
                moduleData.syntax.declarations
                    |> FastDict.LocalExtra.unionFromListWithMap
                        (\(Elm.Syntax.Node.Node _ declaration) ->
                            declaration
                                |> Declaration.LocalExtra.identifierUses
                                |> FastDict.map (\_ ranges -> ranges |> List.length)
                        )
                        (+)
            , importsExposingAll =
                moduleData.syntax.imports
                    |> List.filterMap
                        (\(Elm.Syntax.Node.Node _ import_) ->
                            case import_.exposingList |> Maybe.map Elm.Syntax.Node.value of
                                Nothing ->
                                    Nothing

                                Just (Elm.Syntax.Exposing.Explicit _) ->
                                    Nothing

                                Just (Elm.Syntax.Exposing.All _) ->
                                    { moduleName = import_.moduleName |> Elm.Syntax.Node.value
                                    , alias = import_.moduleAlias |> Maybe.map (\(Elm.Syntax.Node.Node _ aliasParts) -> aliasParts |> String.join ".")
                                    }
                                        |> Just
                        )
            , importsExposingExplicit =
                moduleData.syntax.imports
                    |> List.filterMap
                        (\(Elm.Syntax.Node.Node _ import_) ->
                            (case import_.exposingList |> Maybe.map Elm.Syntax.Node.value of
                                Just (Elm.Syntax.Exposing.All _) ->
                                    Nothing

                                Nothing ->
                                    { simpleNames = Set.empty, typesExposingVariants = Set.empty }
                                        |> Just

                                Just (Elm.Syntax.Exposing.Explicit topLevelExposeList) ->
                                    topLevelExposeList |> Review.topLevelExposeListToExposes |> Just
                            )
                                |> Maybe.map
                                    (\exposes ->
                                        { moduleName = import_.moduleName |> Elm.Syntax.Node.value
                                        , alias = import_.moduleAlias |> Maybe.map (\(Elm.Syntax.Node.Node _ aliasParts) -> aliasParts |> String.join ".")
                                        , simpleNames = exposes.simpleNames
                                        , typesExposingVariants = exposes.typesExposingVariants
                                        }
                                    )
                        )
            }
                |> FastDict.singleton moduleName
        , moduleExposes =
            let
                exposes :
                    { range : Elm.Syntax.Range.Range
                    , simpleNames : FastDict.Dict String Elm.Syntax.Range.Range
                    , typesWithVariantNames : FastDict.Dict String { range : Elm.Syntax.Range.Range, variants : Set String }
                    }
                exposes =
                    moduleData.syntax |> moduleToExposes
            in
            FastDict.singleton
                moduleName
                { path = moduleData.path
                , exposingRange = exposes.range
                , exposedSimpleNames = exposes.simpleNames
                , exposedTypesWithVariantNames = exposes.typesWithVariantNames
                }
        , modulesAllowingUnusedExposes = Set.empty
        , moduleImports =
            moduleData.syntax.imports
                |> List.foldl
                    (\(Elm.Syntax.Node.Node importLineRange import_) soFar ->
                        soFar
                            |> FastDict.update (import_.moduleName |> Elm.Syntax.Node.value)
                                (\rangesSoFar ->
                                    rangesSoFar
                                        |> Maybe.withDefault []
                                        |> (::)
                                            { path = moduleData.path
                                            , row = importLineRange.start.row
                                            }
                                        |> Just
                                )
                    )
                    FastDict.empty
        }


moduleToExposes :
    Elm.Syntax.File.File
    ->
        { range : Elm.Syntax.Range.Range
        , simpleNames : FastDict.Dict String Elm.Syntax.Range.Range
        , typesWithVariantNames : FastDict.Dict String { range : Elm.Syntax.Range.Range, variants : Set String }
        }
moduleToExposes syntaxFile =
    let
        moduleTypesWithVariantNames : FastDict.Dict String (Set String)
        moduleTypesWithVariantNames =
            syntaxFile.declarations
                |> List.filterMap
                    (\(Elm.Syntax.Node.Node _ declaration) ->
                        case declaration of
                            Elm.Syntax.Declaration.CustomTypeDeclaration choiceTypeDeclaration ->
                                ( choiceTypeDeclaration.name |> Elm.Syntax.Node.value
                                , choiceTypeDeclaration.constructors
                                    |> List.map
                                        (\(Elm.Syntax.Node.Node _ constructor) ->
                                            constructor.name |> Elm.Syntax.Node.value
                                        )
                                    |> Set.fromList
                                )
                                    |> Just

                            _ ->
                                Nothing
                    )
                |> FastDict.fromList
    in
    case syntaxFile.moduleDefinition |> moduleHeaderExposingNode of
        Elm.Syntax.Node.Node range (Elm.Syntax.Exposing.Explicit exposeSet) ->
            exposeSet
                |> List.foldl
                    (\(Elm.Syntax.Node.Node exposeRange expose) soFar ->
                        case expose of
                            Elm.Syntax.Exposing.TypeExpose choiceTypeExpose ->
                                case choiceTypeExpose.open of
                                    Nothing ->
                                        { soFar
                                            | simpleNames = soFar.simpleNames |> FastDict.insert choiceTypeExpose.name exposeRange
                                        }

                                    Just _ ->
                                        moduleTypesWithVariantNames
                                            |> FastDict.get choiceTypeExpose.name
                                            |> Maybe.map
                                                (\variantNames ->
                                                    { soFar
                                                        | typesWithVariantNames =
                                                            soFar.typesWithVariantNames
                                                                |> FastDict.insert choiceTypeExpose.name
                                                                    { range = exposeRange
                                                                    , variants = variantNames
                                                                    }
                                                    }
                                                )
                                            |> Maybe.withDefault soFar

                            Elm.Syntax.Exposing.FunctionExpose valueOrFunctionName ->
                                { soFar
                                    | simpleNames =
                                        soFar.simpleNames |> FastDict.insert valueOrFunctionName exposeRange
                                }

                            Elm.Syntax.Exposing.TypeOrAliasExpose exposeName ->
                                { soFar
                                    | simpleNames =
                                        soFar.simpleNames |> FastDict.insert exposeName exposeRange
                                }

                            Elm.Syntax.Exposing.InfixExpose symbol ->
                                { soFar
                                    | simpleNames =
                                        soFar.simpleNames |> FastDict.insert ("(" ++ symbol ++ ")") exposeRange
                                }
                    )
                    { range = range
                    , simpleNames = FastDict.empty
                    , typesWithVariantNames = FastDict.empty
                    }

        Elm.Syntax.Node.Node range (Elm.Syntax.Exposing.All allRange) ->
            { range = range
            , simpleNames =
                syntaxFile.declarations
                    |> List.foldl
                        (\(Elm.Syntax.Node.Node _ declaration) soFar ->
                            case declaration of
                                Elm.Syntax.Declaration.CustomTypeDeclaration _ ->
                                    soFar

                                Elm.Syntax.Declaration.FunctionDeclaration valueOrFunctionDeclaration ->
                                    soFar
                                        |> FastDict.insert
                                            (valueOrFunctionDeclaration.declaration
                                                |> Elm.Syntax.Node.value
                                                |> .name
                                                |> Elm.Syntax.Node.value
                                            )
                                            allRange

                                Elm.Syntax.Declaration.AliasDeclaration typeAliasDeclaration ->
                                    soFar |> FastDict.insert (typeAliasDeclaration.name |> Elm.Syntax.Node.value) allRange

                                Elm.Syntax.Declaration.PortDeclaration signature ->
                                    soFar |> FastDict.insert (signature.name |> Elm.Syntax.Node.value) allRange

                                Elm.Syntax.Declaration.InfixDeclaration symbol ->
                                    soFar |> FastDict.insert (symbol.function |> Elm.Syntax.Node.value) allRange

                                -- invalid elm
                                Elm.Syntax.Declaration.Destructuring _ _ ->
                                    soFar
                        )
                        FastDict.empty
            , typesWithVariantNames =
                moduleTypesWithVariantNames
                    |> FastDict.map (\_ variants -> { variants = variants, range = allRange })
            }


moduleHeaderExposingNode : Elm.Syntax.Node.Node Elm.Syntax.Module.Module -> Elm.Syntax.Node.Node Elm.Syntax.Exposing.Exposing
moduleHeaderExposingNode =
    \(Elm.Syntax.Node.Node _ moduleHeader) ->
        case moduleHeader of
            Elm.Syntax.Module.NormalModule moduleHeaderData ->
                moduleHeaderData.exposingList

            Elm.Syntax.Module.PortModule moduleHeaderData ->
                moduleHeaderData.exposingList

            Elm.Syntax.Module.EffectModule moduleHeaderData ->
                moduleHeaderData.exposingList


knowledgeMerge : Knowledge -> Knowledge -> Knowledge
knowledgeMerge a b =
    { moduleExposes = FastDict.union a.moduleExposes b.moduleExposes
    , identifierUseCounts =
        FastDict.union a.identifierUseCounts b.identifierUseCounts
    , modulesAllowingUnusedExposes =
        Set.union a.modulesAllowingUnusedExposes b.modulesAllowingUnusedExposes
    , moduleImports =
        FastDict.LocalExtra.unionWith (++)
            a.moduleImports
            b.moduleImports
    }


report : Knowledge -> List Review.Error
report knowledge =
    let
        allFullyQualifiedIdentifierUseCounts : FastDict.Dict Elm.Syntax.ModuleName.ModuleName (FastDict.Dict ( List String, String ) Int)
        allFullyQualifiedIdentifierUseCounts =
            knowledge.identifierUseCounts
                |> FastDict.map
                    (\_ identifierUseCountsForModule ->
                        let
                            explicitImports :
                                FastDict.Dict
                                    Elm.Syntax.ModuleName.ModuleName
                                    { alias : Maybe String
                                    , exposes : Set String -- includes names of variants
                                    }
                            explicitImports =
                                Review.importsToExplicit
                                    { moduleExposes =
                                        knowledge.moduleExposes
                                            |> FastDict.map
                                                (\_ moduleExposes ->
                                                    { simpleNames =
                                                        moduleExposes.exposedSimpleNames
                                                            |> FastDict.LocalExtra.keys
                                                    , typesWithVariantNames =
                                                        moduleExposes.exposedTypesWithVariantNames
                                                            |> FastDict.map (\_ rangeAndVariantNames -> rangeAndVariantNames.variants)
                                                    }
                                                )
                                    , importsExposingExplicit = identifierUseCountsForModule.importsExposingExplicit
                                    , importsExposingAll = identifierUseCountsForModule.importsExposingAll
                                    }
                        in
                        identifierUseCountsForModule.identifierUseCounts
                            |> FastDict.foldl
                                (\( qualification, unqualified ) referenceCount soFar ->
                                    soFar
                                        |> FastDict.update
                                            ( ( qualification, unqualified ) |> Review.determineModuleOrigin explicitImports |> Maybe.withDefault []
                                            , unqualified
                                            )
                                            (\countSoFar ->
                                                (countSoFar |> Maybe.withDefault 0)
                                                    + referenceCount
                                                    |> Just
                                            )
                                )
                                FastDict.empty
                    )
    in
    knowledge.moduleExposes
        |> FastDict.LocalExtra.justsToListMap
            (\moduleName moduleExposes ->
                if knowledge.modulesAllowingUnusedExposes |> Set.member moduleName then
                    Nothing

                else
                    Just { name = moduleName, exposes = moduleExposes }
            )
        |> List.concatMap
            (\moduleKnowledge ->
                let
                    usedReferences : Set ( Elm.Syntax.ModuleName.ModuleName, String )
                    usedReferences =
                        allFullyQualifiedIdentifierUseCounts
                            |> FastDict.remove moduleKnowledge.name
                            |> FastDict.foldl
                                (\_ identifierUseCounts soFar ->
                                    FastDict.LocalExtra.unionWith (+) soFar identifierUseCounts
                                )
                                FastDict.empty
                            |> FastDict.LocalExtra.keys
                            |> Set.insert ( moduleKnowledge.name, "main" )
                in
                [ moduleKnowledge.exposes.exposedSimpleNames
                    |> FastDict.LocalExtra.justsToListMap
                        (\exposeUnqualified exposeRange ->
                            if usedReferences |> Set.member ( moduleKnowledge.name, exposeUnqualified ) then
                                Nothing

                            else
                                let
                                    fixedExposes : Set String
                                    fixedExposes =
                                        Set.union
                                            (moduleKnowledge.exposes.exposedSimpleNames
                                                |> FastDict.LocalExtra.keys
                                                |> Set.remove exposeUnqualified
                                            )
                                            (moduleKnowledge.exposes.exposedTypesWithVariantNames
                                                |> FastDict.LocalExtra.keys
                                            )
                                in
                                if fixedExposes |> Set.isEmpty then
                                    { path = moduleKnowledge.exposes.path
                                    , message = [ "module ", moduleKnowledge.name |> String.join ".", " isn't used" ] |> String.concat
                                    , details =
                                        [ "Since all exposed members aren't used outside of this module, the whole module is unused."
                                        , """Unused code might be a sign that someone wanted to use it for something but didn't do so, yet.
But maybe you've since moved in a different direction,
in which case allowing the unused code to sit can make it harder to find what's important."""
                                        , """If intended for determined future use, try gradually using it.
If intended as a very generic utility, try moving it into a package
(possibly local-only, using `Review.ignoreErrorsForPathsWhere (String.startsWith "your-local-package-source-directory")`).
If you think you don't need it anymore or think it was added it prematurely, you can remove it manually."""
                                        ]
                                    , range = exposeRange
                                    , fix =
                                        case knowledge.moduleImports |> FastDict.get moduleKnowledge.name of
                                            Nothing ->
                                                []

                                            Just moduleImports ->
                                                moduleImports
                                                    |> List.map
                                                        (\moduleImport ->
                                                            { path = moduleImport.path
                                                            , edits =
                                                                [ Review.removeRange
                                                                    { start = { row = moduleImport.row, column = 1 }
                                                                    , end = { row = moduleImport.row + 1, column = 1 }
                                                                    }
                                                                ]
                                                            }
                                                        )
                                    }
                                        |> Just

                                else
                                    { path = moduleKnowledge.exposes.path
                                    , message = [ "expose ", ( moduleKnowledge.name, exposeUnqualified ) |> referenceToString, " isn't used outside of this module" ] |> String.concat
                                    , details =
                                        [ "Since all exposed members aren't used outside of this module, the whole module is unused."
                                        , """Unused code might be a sign that someone wanted to use it for something but didn't do so, yet.
But maybe you've since moved in a different direction,
in which case allowing the unused code to sit can make it harder to find what's important."""
                                        , """If intended for determined future use, try gradually using it.
If intended as a very generic utility, try moving it into a package
(possibly local-only, using `Review.ignoreErrorsForPathsWhere (String.startsWith "your-local-package-source-directory")`).
If you think you don't need it anymore or think it was added it prematurely, you can remove it from the exposing part of the module header by applying the provided fix which might reveal its declaration as unused."""
                                        ]
                                    , range = exposeRange
                                    , fix =
                                        [ { path = moduleKnowledge.exposes.path
                                          , edits =
                                                [ Review.replaceRange moduleKnowledge.exposes.exposingRange
                                                    (fixedExposes |> exposingToString)
                                                ]
                                          }
                                        ]
                                    }
                                        |> Just
                        )
                , moduleKnowledge.exposes.exposedTypesWithVariantNames
                    |> FastDict.LocalExtra.justsToListMap
                        (\typeExposeUnqualified typeExpose ->
                            let
                                typeExposeVariantReferences : () -> Set ( Elm.Syntax.ModuleName.ModuleName, String )
                                typeExposeVariantReferences () =
                                    typeExpose.variants |> Set.map (\unqualified -> ( moduleKnowledge.name, unqualified ))
                            in
                            if
                                (usedReferences |> Set.member ( moduleKnowledge.name, typeExposeUnqualified ))
                                    && (Set.diff (typeExposeVariantReferences ()) usedReferences |> Set.isEmpty)
                            then
                                { path = moduleKnowledge.exposes.path
                                , message = [ "expose ", ( moduleKnowledge.name, typeExposeUnqualified ) |> referenceToString, " isn't used outside of this module" ] |> String.concat
                                , details =
                                    [ "Either use it or remove it from the exposing part of the module header which might reveal its declaration as unused." ]
                                , range = typeExpose.range
                                , fix =
                                    [ { path = moduleKnowledge.exposes.path
                                      , edits =
                                            [ Review.replaceRange moduleKnowledge.exposes.exposingRange
                                                (Set.union
                                                    (moduleKnowledge.exposes.exposedSimpleNames
                                                        |> FastDict.LocalExtra.keys
                                                    )
                                                    (moduleKnowledge.exposes.exposedTypesWithVariantNames
                                                        |> FastDict.LocalExtra.keys
                                                        |> Set.remove typeExposeUnqualified
                                                    )
                                                    |> exposingToString
                                                )
                                            ]
                                      }
                                    ]
                                }
                                    |> Just

                            else
                                Nothing
                        )
                ]
                    |> List.concat
            )


exposingToString : Set String -> String
exposingToString =
    \exposes ->
        [ "exposing (", exposes |> Set.toList |> String.join ", ", ")" ] |> String.concat


referenceToString : ( Elm.Syntax.ModuleName.ModuleName, String ) -> String
referenceToString =
    \( moduleName, name ) ->
        [ moduleName |> String.join ".", ".", name ] |> String.concat
