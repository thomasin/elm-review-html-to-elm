module HtmlToTailwind exposing (htmlToElmTailwindModules)

import Config exposing (Config)
import Dict exposing (Dict)
import Dict.Extra
import FormattedElm exposing (indentation, indentedThingy)
import Html.Parser
import ImplementedFunctions
import Regex


htmlToElmTailwindModules : Config -> String -> String
htmlToElmTailwindModules config input =
    case Html.Parser.run input of
        Err _ ->
            "ERROR"

        Ok value ->
            List.filterMap (nodeToElm config 1 Html) value |> join


type Separator
    = CommaSeparator
    | NoSeparator


join : List ( Separator, String ) -> String
join nodes =
    case nodes of
        [] ->
            ""

        [ ( _, singleNode ) ] ->
            singleNode

        ( separator1, node1 ) :: otherNodes ->
            case separator1 of
                NoSeparator ->
                    node1 ++ "" ++ join otherNodes

                CommaSeparator ->
                    node1 ++ ", " ++ join otherNodes


nodeToElm : Config -> Int -> Context -> Html.Parser.Node -> Maybe ( Separator, String )
nodeToElm config indentLevel context node =
    case node of
        Html.Parser.Text textBody ->
            let
                trimmed : String
                trimmed =
                    String.trim textBody
                        |> Regex.replace
                            (Regex.fromString "\\s+"
                                |> Maybe.withDefault Regex.never
                            )
                            (\_ -> " ")
            in
            if String.isEmpty trimmed then
                Nothing

            else
                ( CommaSeparator, Config.htmlTag config "text" ++ " \"" ++ trimmed ++ "\"" ) |> Just

        Html.Parser.Element elementName attributes children ->
            let
                elementFunction : String
                elementFunction =
                    case newContext of
                        Svg ->
                            case ImplementedFunctions.lookup ImplementedFunctions.svgTags elementName of
                                Just functionName ->
                                    Config.svgTag config functionName

                                Nothing ->
                                    Config.svgTag config "node" ++ " \"" ++ elementName ++ "\""

                        Html ->
                            case ImplementedFunctions.lookupWithDict ImplementedFunctions.htmlTagsDict ImplementedFunctions.htmlTags elementName of
                                Just functionName ->
                                    Config.htmlTag config functionName

                                Nothing ->
                                    Config.htmlTag config "node" ++ " \"" ++ elementName ++ "\""

                isSvg : Bool
                isSvg =
                    isSvgContext attributes

                newContext : Context
                newContext =
                    if isSvg then
                        Svg

                    else
                        context

                filteredAttributes : List String
                filteredAttributes =
                    List.concatMap
                        (\attribute ->
                            attribute
                                |> attributeToElm config
                                    (indentLevel + 1)
                                    newContext
                        )
                        attributes
            in
            ( CommaSeparator
            , (if indentLevel == 1 then
                "    "

               else
                ""
              )
                ++ elementFunction
                ++ (indentedThingy (indentLevel + 1) identity filteredAttributes
                        ++ indentation indentLevel
                        ++ "      ["
                        ++ (List.filterMap (nodeToElm config (indentLevel + 1) newContext) children |> join |> surroundWithSpaces)
                        ++ "]\n"
                        ++ indentation indentLevel
                   )
            )
                |> Just

        Html.Parser.Comment string ->
            Just <| ( NoSeparator, indentation indentLevel ++ "{-" ++ string ++ "-}\n" ++ indentation indentLevel )


isSvgContext : List ( String, String ) -> Bool
isSvgContext attributes =
    attributes
        |> List.any (\( key, _ ) -> key == "xmlns")


type Context
    = Html
    | Svg


escapedString : String -> String
escapedString string =
    string
        |> String.replace "\"" "\\\""
        |> String.replace "\n" "\\n"


attributeToElm : Config -> Int -> Context -> Html.Parser.Attribute -> List String
attributeToElm config indentLevel context ( name, value ) =
    if name == "xmlns" then
        []

    else if name == "class" && config.useTailwindModules then
        [ classAttributeToElm config context indentLevel value ]

    else if context == Svg then
        [ svgAttr config ( name, value ) ]

    else if name == "style" then
        value
            |> String.split ";"
            |> List.filter (not << String.isEmpty)
            |> List.map
                (\entry ->
                    case entry |> String.split ":" of
                        [ styleName, styleValue ] ->
                            Config.htmlAttr config "style"
                                ++ " \""
                                ++ String.trim styleName
                                ++ "\" \""
                                ++ escapedString (String.trim styleValue)
                                ++ "\""

                        _ ->
                            "<Invalid" ++ entry ++ ">"
                )

    else
        case ImplementedFunctions.lookup ImplementedFunctions.boolAttributeFunctions name of
            Just boolFunction ->
                [ Config.htmlAttr config boolFunction ++ " True" ]

            Nothing ->
                case ImplementedFunctions.lookup ImplementedFunctions.intAttributeFunctions name of
                    Just intFunction ->
                        [ Config.htmlAttr config intFunction ++ " " ++ value ]

                    Nothing ->
                        case ImplementedFunctions.lookupWithDict ImplementedFunctions.htmlAttributeDict ImplementedFunctions.htmlAttributes name of
                            Just functionName ->
                                [ Config.htmlAttr config functionName ++ " \"" ++ value ++ "\"" ]

                            Nothing ->
                                [ Config.htmlAttr config "attribute" ++ " \"" ++ name ++ "\" \"" ++ escapedString value ++ "\"" ]


svgAttr : Config -> ( String, String ) -> String
svgAttr config ( name, value ) =
    case ImplementedFunctions.lookup ImplementedFunctions.svgAttributes name of
        Just functionName ->
            Config.svgAttr config (ImplementedFunctions.toCamelCase functionName) ++ " \"" ++ value ++ "\""

        Nothing ->
            Config.htmlAttr config "attribute" ++ " \"" ++ name ++ "\" \"" ++ value ++ "\""


classAttributeToElm : Config -> Context -> Int -> String -> String
classAttributeToElm config context indentLevel value =
    let
        dict : Dict String (Dict String (List String))
        dict =
            value
                |> String.split " "
                |> List.map String.trim
                |> List.filter (\item -> not (String.isEmpty item))
                |> List.map splitOutBreakpoints
                |> Dict.Extra.groupBy .breakpoint
                |> Dict.map
                    (\_ v ->
                        v
                            |> Dict.Extra.groupBy .pseudoClass
                            |> Dict.map
                                (\_ v2 ->
                                    List.map .tailwindClass v2
                                )
                    )

        newThing : List String
        newThing =
            dict
                |> Dict.toList
                |> List.map
                    (\( breakpoint, twClasses ) ->
                        if breakpoint == "" then
                            let
                                allClasses : List String
                                allClasses =
                                    twClasses
                                        |> Dict.values
                                        |> List.concat
                            in
                            allClasses
                                |> List.map (toTwClass config)

                        else
                            twClasses
                                |> Dict.toList
                                |> List.map
                                    (\( pseudoclass, twClassList ) ->
                                        if pseudoclass == "" then
                                            twClassList
                                                |> List.map (toTwClass config)

                                        else
                                            case ImplementedFunctions.lookupWithDict ImplementedFunctions.pseudoClasses ImplementedFunctions.cssHelpers pseudoclass of
                                                Just functionName ->
                                                    [ "Css."
                                                        ++ functionName
                                                        ++ " "
                                                        ++ indentedThingy (indentLevel + 3) (toTwClass config) twClassList
                                                    ]

                                                Nothing ->
                                                    [ Config.bp config breakpoint
                                                        ++ indentedThingy (indentLevel + 3) (toTwClass config) twClassList
                                                    ]
                                    )
                                |> List.concat
                                --|> List.map (\thing -> indentedThingy (indentLevel + 2) identity thing)
                                |> (\thing ->
                                        [ breakpointName config breakpoint
                                            ++ indentedThingy (indentLevel + 2) identity thing
                                        ]
                                   )
                    )
                |> List.concat

        cssFunction : String
        cssFunction =
            case context of
                Html ->
                    Config.htmlAttr config "css"

                Svg ->
                    Config.svgAttr config "css"
    in
    cssFunction ++ indentedThingy (indentLevel + 1) identity newThing


breakpointName : Config -> String -> String
breakpointName config breakpoint =
    case ImplementedFunctions.lookupWithDict ImplementedFunctions.pseudoClasses ImplementedFunctions.cssHelpers breakpoint of
        Just functionName ->
            "Css." ++ functionName

        Nothing ->
            Config.bp config breakpoint


toTwClass : Config -> String -> String
toTwClass config twClass =
    Config.tw config (twClassToElmName twClass)


{-| Mimics the rules in <https://github.com/matheus23/elm-tailwind-modules/blob/cd5809505934ff72c9b54fd1e181f67b53af8186/src/helpers.ts#L24-L59>
-}
twClassToElmName : String -> String
twClassToElmName twClass =
    twClass
        |> Regex.replace (Regex.fromString "^-([a-z])" |> Maybe.withDefault Regex.never)
            (\match ->
                "neg_" ++ (match.submatches |> List.head |> Maybe.andThen identity |> Maybe.withDefault "")
            )
        |> Regex.replace (Regex.fromString "\\." |> Maybe.withDefault Regex.never)
            (\_ ->
                "_dot_"
            )
        |> String.replace "/" "over"
        |> String.replace "-" "_"


splitOutBreakpoints : String -> { breakpoint : String, pseudoClass : String, tailwindClass : String }
splitOutBreakpoints tailwindClassName =
    case String.split ":" tailwindClassName of
        [ breakpoint, pseudoClass, tailwindClass ] ->
            { breakpoint = breakpoint
            , pseudoClass = pseudoClass
            , tailwindClass = tailwindClass
            }

        [ breakpoint, tailwindClass ] ->
            { breakpoint = breakpoint
            , pseudoClass = ""
            , tailwindClass = tailwindClass
            }

        [ tailwindClass ] ->
            { breakpoint = ""
            , pseudoClass = ""
            , tailwindClass = tailwindClass
            }

        _ ->
            { breakpoint = ""
            , pseudoClass = ""
            , tailwindClass = ""
            }


surroundWithSpaces : String -> String
surroundWithSpaces string =
    if String.isEmpty string then
        string

    else
        " " ++ string ++ " "
