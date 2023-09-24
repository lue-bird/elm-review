module Review.Rule.VisitorsOrderTest exposing (all)

import Elm.Syntax.Declaration exposing (Declaration)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern exposing (Pattern)
import Review.Rule as Rule exposing (Error, Rule)
import Review.Test
import Test exposing (Test, test)


type alias Context =
    String


all : Test
all =
    Test.describe "Visitor order"
        [ test "should call visitors in a given order" <|
            \() ->
                let
                    importName : Node Import -> String
                    importName (Node _ import_) =
                        String.join "." (Node.value import_.moduleName)

                    rule : Rule
                    rule =
                        Rule.newModuleRuleSchema "Visitor order" (Rule.initContextCreator "\n0 - initial context")
                            |> Rule.withModuleDefinitionVisitor (\_ context -> ( [], context ++ "\n1.1 - withModuleDefinitionVisitor" ))
                            |> Rule.withModuleDefinitionVisitor (\_ context -> ( [], context ++ "\n1.2 - withModuleDefinitionVisitor" ))
                            |> Rule.withModuleDocumentationVisitor (\_ context -> ( [], context ++ "\n2.1 - withModuleDocumentationVisitor" ))
                            |> Rule.withModuleDocumentationVisitor (\_ context -> ( [], context ++ "\n2.2 - withModuleDocumentationVisitor" ))
                            |> Rule.withCommentsVisitor (\_ context -> ( [], context ++ "\n3.1 - withCommentsVisitor" ))
                            |> Rule.withCommentsVisitor (\_ context -> ( [], context ++ "\n3.2 - withCommentsVisitor" ))
                            |> Rule.withImportVisitor (\import_ context -> ( [], context ++ "\n4.1 - withImportVisitor " ++ importName import_ ))
                            |> Rule.withImportVisitor (\import_ context -> ( [], context ++ "\n4.2 - withImportVisitor " ++ importName import_ ))
                            |> Rule.withDeclarationListVisitor (\_ context -> ( [], context ++ "\n5.1 - withDeclarationListVisitor" ))
                            |> Rule.withDeclarationListVisitor (\_ context -> ( [], context ++ "\n5.2 - withDeclarationListVisitor" ))
                            |> Rule.withDeclarationEnterVisitor (\_ context -> ( [], context ++ "\n6.1 - withDeclarationEnterVisitor" ))
                            |> Rule.withDeclarationEnterVisitor (\_ context -> ( [], context ++ "\n6.2 - withDeclarationEnterVisitor" ))
                            |> Rule.withDeclarationExitVisitor (\_ context -> ( [], context ++ "\n9.2 - withDeclarationExitVisitor" ))
                            |> Rule.withDeclarationExitVisitor (\_ context -> ( [], context ++ "\n9.1 - withDeclarationExitVisitor" ))
                            |> Rule.withExpressionEnterVisitor (\_ context -> ( [], context ++ "\n7.1 - withExpressionEnterVisitor" ))
                            |> Rule.withExpressionEnterVisitor (\_ context -> ( [], context ++ "\n7.2 - withExpressionEnterVisitor" ))
                            |> Rule.withExpressionExitVisitor (\_ context -> ( [], context ++ "\n8.2 - withExpressionExitVisitor" ))
                            |> Rule.withExpressionExitVisitor (\_ context -> ( [], context ++ "\n8.1 - withExpressionExitVisitor" ))
                            |> Rule.withFinalModuleEvaluation finalEvaluation
                            |> Rule.fromModuleRuleSchema

                    finalEvaluation : Context -> List (Error {})
                    finalEvaluation context =
                        [ Rule.error { message = context, details = [ "details" ] }
                            { start = { row = 1, column = 1 }
                            , end = { row = 1, column = 7 }
                            }
                        ]
                in
                """module A exposing (..)
import B
import C
a = 1
"""
                    |> Review.Test.run rule
                    |> Review.Test.expectErrors
                        [ Review.Test.error
                            { message = """
0 - initial context
1.1 - withModuleDefinitionVisitor
1.2 - withModuleDefinitionVisitor
2.1 - withModuleDocumentationVisitor
2.2 - withModuleDocumentationVisitor
3.1 - withCommentsVisitor
3.2 - withCommentsVisitor
4.1 - withImportVisitor B
4.2 - withImportVisitor B
4.1 - withImportVisitor C
4.2 - withImportVisitor C
5.1 - withDeclarationListVisitor
5.2 - withDeclarationListVisitor
6.1 - withDeclarationEnterVisitor
6.2 - withDeclarationEnterVisitor
7.1 - withExpressionEnterVisitor
7.2 - withExpressionEnterVisitor
8.1 - withExpressionExitVisitor
8.2 - withExpressionExitVisitor
9.1 - withDeclarationExitVisitor
9.2 - withDeclarationExitVisitor"""
                            , details = [ "details" ]
                            , under = "module"
                            }
                        ]
        , test "should call the same type of visitors in order of call on enter, and reverse order on exit (expression)" <|
            \() ->
                let
                    rule : Rule
                    rule =
                        Rule.newModuleRuleSchema "TestRule" (Rule.initContextCreator "")
                            |> Rule.withExpressionEnterVisitor (declarationEnterVisitor "A")
                            |> Rule.withExpressionExitVisitor (declarationExitVisitor "A")
                            |> Rule.withExpressionEnterVisitor (declarationEnterVisitor "B")
                            |> Rule.withExpressionExitVisitor (declarationExitVisitor "B")
                            |> Rule.withExpressionEnterVisitor (declarationEnterVisitor "C")
                            |> Rule.withExpressionExitVisitor (declarationExitVisitor "C")
                            |> Rule.withFinalModuleEvaluation finalEvaluation
                            |> Rule.fromModuleRuleSchema

                    declarationEnterVisitor : String -> Node Expression -> Context -> ( List (Error {}), Context )
                    declarationEnterVisitor text _ context =
                        ( [], context ++ "\nEnter " ++ text )

                    declarationExitVisitor : String -> Node Expression -> Context -> ( List (Error {}), Context )
                    declarationExitVisitor text _ context =
                        ( [], context ++ "\nExit " ++ text )

                    finalEvaluation : Context -> List (Error {})
                    finalEvaluation context =
                        [ Rule.error { message = context, details = [ "details" ] }
                            { start = { row = 1, column = 1 }
                            , end = { row = 1, column = 7 }
                            }
                        ]
                in
                """module A exposing (..)
a = 1
"""
                    |> Review.Test.run rule
                    |> Review.Test.expectErrors
                        [ Review.Test.error
                            { message = """
Enter A
Enter B
Enter C
Exit C
Exit B
Exit A"""
                            , details = [ "details" ]
                            , under = "module"
                            }
                        ]
        , test "should call the same type of visitors in order of call on enter, and reverse order on exit (declaration)" <|
            \() ->
                let
                    rule : Rule
                    rule =
                        Rule.newModuleRuleSchema "TestRule" (Rule.initContextCreator "")
                            |> Rule.withDeclarationEnterVisitor (declarationEnterVisitor "A")
                            |> Rule.withDeclarationExitVisitor (declarationExitVisitor "A")
                            |> Rule.withDeclarationEnterVisitor (declarationEnterVisitor "B")
                            |> Rule.withDeclarationExitVisitor (declarationExitVisitor "B")
                            |> Rule.withDeclarationEnterVisitor (declarationEnterVisitor "C")
                            |> Rule.withDeclarationExitVisitor (declarationExitVisitor "C")
                            |> Rule.withFinalModuleEvaluation finalEvaluation
                            |> Rule.fromModuleRuleSchema

                    declarationEnterVisitor : String -> Node Declaration -> Context -> ( List (Error {}), Context )
                    declarationEnterVisitor text _ context =
                        ( [], context ++ "\nEnter " ++ text )

                    declarationExitVisitor : String -> Node Declaration -> Context -> ( List (Error {}), Context )
                    declarationExitVisitor text _ context =
                        ( [], context ++ "\nExit " ++ text )

                    finalEvaluation : Context -> List (Error {})
                    finalEvaluation context =
                        [ Rule.error { message = context, details = [ "details" ] }
                            { start = { row = 1, column = 1 }
                            , end = { row = 1, column = 7 }
                            }
                        ]
                in
                """module A exposing (..)
a = 1
"""
                    |> Review.Test.run rule
                    |> Review.Test.expectErrors
                        [ Review.Test.error
                            { message = """
Enter A
Enter B
Enter C
Exit C
Exit B
Exit A"""
                            , details = [ "details" ]
                            , under = "module"
                            }
                        ]
        , test "should call the same type of visitors in order of call on enter, and reverse order on exit (let declaration)" <|
            \() ->
                let
                    rule : Rule
                    rule =
                        Rule.newModuleRuleSchema "TestRule" (Rule.initContextCreator "")
                            |> Rule.withLetDeclarationEnterVisitor (letDeclarationVisitor "A enter")
                            |> Rule.withLetDeclarationEnterVisitor (letDeclarationVisitor "B enter")
                            |> Rule.withLetDeclarationExitVisitor (letDeclarationVisitor "C exit")
                            |> Rule.withLetDeclarationExitVisitor (letDeclarationVisitor "D exit")
                            |> Rule.withFinalModuleEvaluation finalEvaluation
                            |> Rule.fromModuleRuleSchema

                    letDeclarationName : Node Expression.LetDeclaration -> String
                    letDeclarationName letDeclaration =
                        case Node.value letDeclaration of
                            Expression.LetFunction { declaration } ->
                                declaration |> Node.value |> .name |> Node.value

                            Expression.LetDestructuring _ _ ->
                                "NOT RELEVANT"

                    letDeclarationVisitor : String -> Node Expression.LetBlock -> Node Expression.LetDeclaration -> Context -> ( List (Error {}), Context )
                    letDeclarationVisitor text _ letDeclaration context =
                        ( [], context ++ "\n" ++ text ++ ": " ++ letDeclarationName letDeclaration )

                    finalEvaluation : Context -> List (Error {})
                    finalEvaluation context =
                        [ Rule.error { message = context, details = [ "details" ] }
                            { start = { row = 1, column = 1 }
                            , end = { row = 1, column = 7 }
                            }
                        ]
                in
                """module A exposing (..)
a =
  let
     b = 1
     c n = n
  in
  b + c 2
"""
                    |> Review.Test.run rule
                    |> Review.Test.expectErrors
                        [ Review.Test.error
                            { message = """
A enter: b
B enter: b
D exit: b
C exit: b
A enter: c
B enter: c
D exit: c
C exit: c"""
                            , details = [ "details" ]
                            , under = "module"
                            }
                        ]
        , test "should call the same type of visitors in order of call on enter, and reverse order on exit (case branch)" <|
            \() ->
                let
                    rule : Rule
                    rule =
                        Rule.newModuleRuleSchema "TestRule" (Rule.initContextCreator "")
                            |> Rule.withCaseBranchEnterVisitor (caseBranchVisitor "A enter")
                            |> Rule.withCaseBranchEnterVisitor (caseBranchVisitor "B enter")
                            |> Rule.withCaseBranchExitVisitor (caseBranchVisitor "C exit")
                            |> Rule.withCaseBranchExitVisitor (caseBranchVisitor "D exit")
                            |> Rule.withFinalModuleEvaluation finalEvaluation
                            |> Rule.fromModuleRuleSchema

                    caseBranchVisitor : String -> Node Expression.CaseBlock -> ( Node Pattern, Node Expression ) -> Context -> ( List (Error {}), Context )
                    caseBranchVisitor text _ ( pattern, _ ) context =
                        ( [], context ++ "\n" ++ text ++ ": " ++ Debug.toString (Node.value pattern) )

                    finalEvaluation : Context -> List (Error {})
                    finalEvaluation context =
                        [ Rule.error { message = context, details = [ "details" ] }
                            { start = { row = 1, column = 1 }
                            , end = { row = 1, column = 7 }
                            }
                        ]
                in
                """module A exposing (..)
a =
  case x of
    1 -> b
    _ -> c
"""
                    |> Review.Test.run rule
                    |> Review.Test.expectErrors
                        [ Review.Test.error
                            { message = """
A enter: IntPattern 1
B enter: IntPattern 1
D exit: IntPattern 1
C exit: IntPattern 1
A enter: AllPattern
B enter: AllPattern
D exit: AllPattern
C exit: AllPattern"""
                            , details = [ "details" ]
                            , under = "module"
                            }
                        ]
        ]
