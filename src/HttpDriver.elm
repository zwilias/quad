module HttpDriver exposing (..)

{- }(main, hueChanges) -}
{- This is a starter app which presents a text label, text field, and a button.
   What you enter in the text field is echoed in the label.  When you press the
   button, the text in the label is reverse.
   This version uses `mdgriffith/elm-ui` for the view functions.
-}

import Browser
import Html exposing (Html)
import Color
import TypedSvg
import TypedSvg.Attributes
import TypedSvg.Types
import Time
import Random
import Http
import Quad exposing (Quad, Proportions, ColorRange, render, Position(..))
import Parameters exposing (..)
import Utility
import Element exposing (..)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input


main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }


type alias Flags =
    {}


type Msg
    = NoOp
    | Tick Time.Posix
    | GetRandomNumbers (List Float)
    | GotSensorValue (Result Http.Error String)
    | SentLedCommand (Result Http.Error ())
    | SentLed2Command (Result Http.Error ())
    | PauseApp
    | RunApp
    | Step
    | AdjustValue DataType Float


type alias Model =
    { count : Int
    , randomNumbers : List Float
    , drawing : List Quad
    , oldDrawing : List Quad
    , depth : Int
    , proportions : Proportions
    , initialColorRange : ColorRange
    , colorRange : ColorRange
    , maxDepth : Int
    , rawSensorValue : Maybe Float
    , sensorValue : Maybe Float
    , stayAliveTreshold : Float
    , appState : AppState
    }


type AppState
    = Resting
    | GeneratingImage
    | Pause


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { count = 0
      , randomNumbers = List.repeat 10 0.1
      , drawing = [ Quad.basic 750 ]
      , oldDrawing = [ Quad.basic 750 ]
      , proportions = Quad.sampleProportions
      , initialColorRange = [ ( 0.5, 0.6 ), ( 0.4, 0.8 ), ( 0.2, 1.0 ), ( 0.99, 1.0 ) ]
      , colorRange = [ ( 0.5, 0.6 ), ( 0.4, 0.8 ), ( 0.2, 1.0 ), ( 0.99, 1.0 ) ]
      , depth = 1
      , maxDepth = 7
      , rawSensorValue = Nothing
      , sensorValue = Nothing
      , stayAliveTreshold = 0.2
      , appState = Resting
      }
    , Cmd.none
    )


hueChange : Float -> List Float
hueChange h =
    [ h, 0, 0, 0 ]


hueSaturationChange : Float -> Float -> List Float
hueSaturationChange h s =
    [ h, 0, 0, 0 ]


hslChange : Float -> Float -> Float -> List Float
hslChange h s l =
    [ h, s, l, 0 ]


hueChanges : List Float -> List (List Float)
hueChanges dhList =
    List.map hueChange dhList


hueSaturationChanges : List Float -> List Float -> List (List Float)
hueSaturationChanges dhList dsList =
    List.map2 hueSaturationChange dhList dsList


hslChanges : List Float -> List Float -> List Float -> List (List Float)
hslChanges dhList dsList dlList =
    List.map3 hslChange dhList dsList dlList


subscriptions model =
    Time.every 200 Tick


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        GetRandomNumbers r ->
            ( { model | randomNumbers = r }, Cmd.none )

        PauseApp ->
            ( { model | appState = Pause }, Cmd.none )

        RunApp ->
            ( { model | appState = Resting }, Cmd.none )

        Step ->
            ( { model
                | appState = GeneratingImage
                , drawing = [ Quad.basic 750 ]
                , depth = 1
              }
            , Cmd.none
            )

        AdjustValue dataType value ->
            ( setValue model dataType value, Cmd.none )

        Tick t ->
            if model.depth < model.maxDepth && model.appState /= Pause then
                let
                    rands =
                        model.randomNumbers
                            |> List.map (\x -> (2 * x - 1) / 8.0)

                    newProportions =
                        if model.depth > 1 then
                            Quad.addChangesToProportions 0.2 0.8 (List.take 4 rands) model.proportions
                        else
                            model.proportions

                    colorChanges =
                        hslChanges (List.take 5 rands) (List.drop 5 rands) (List.drop 5 rands)

                    newDrawing =
                        Quad.update
                            model.stayAliveTreshold
                            model.randomNumbers
                            model.colorRange
                            colorChanges
                            newProportions
                            model.drawing
                in
                    ( { model
                        | depth = model.depth + 1
                        , drawing = newDrawing
                        , oldDrawing = model.drawing
                        , proportions = newProportions
                        , appState = GeneratingImage
                      }
                    , Cmd.batch
                        [ Random.generate GetRandomNumbers (Random.list 10 (Random.float 0 1))
                        , ledCommand model
                        ]
                    )
            else
                case model.appState of
                    Pause ->
                        ( model, Cmd.none )

                    _ ->
                        ( { model | appState = Resting }, Cmd.batch [ getSensorValue, ledCommand model ] )

        SentLedCommand result ->
            ( { model | count = model.count + 1 }, Cmd.none )

        SentLed2Command result ->
            ( model, Cmd.none )

        GotSensorValue result ->
            case result of
                Ok str ->
                    let
                        rawSensorValue =
                            String.toFloat str

                        newRawSensorValue =
                            case ( model.rawSensorValue, rawSensorValue ) of
                                ( Just oldValue, Just newValue ) ->
                                    Just (0.5 * newValue + 0.5 * oldValue)
                                        |> Maybe.map (Utility.roundToPlaces 0)

                                ( _, _ ) ->
                                    rawSensorValue

                        sensorValue =
                            rawSensorValue |> Maybe.map (Utility.mapToRange 1 50 0 1)

                        newDepth =
                            resetDepth sensorValue model

                        newDrawing =
                            if newDepth == 1 then
                                [ Quad.basic 750 ]
                            else
                                model.drawing
                    in
                        ( { model
                            | rawSensorValue = newRawSensorValue
                            , sensorValue = sensorValue
                            , colorRange = setColorRange sensorValue model.colorRange
                            , depth = resetDepth sensorValue model
                            , drawing = newDrawing
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )


view : Model -> Html Msg
view model =
    Element.layoutWith { options = [ focusStyle myFocusStyle ] } [] (mainRow model)


myFocusStyle =
    { borderColor = Nothing, backgroundColor = Nothing, shadow = Nothing }


mainRow : Model -> Element Msg
mainRow model =
    Element.row [ width fill ]
        [ Element.html (viewSvg model), controlPanel model ]


edges =
    { top = 0
    , right = 0
    , bottom = 0
    , left = 0
    }


controlPanel model =
    Element.column [ width fill, height fill, paddingEach { edges | left = 96, top = 24 }, spacing 24, Background.color <| Element.rgb 0.1 0.1 0.1 ]
        [ Element.el controlLabelStyle (text "Quad Art Composer")
        , Element.row [ spacing 8 ]
            [ runButton (model.appState /= Pause)
            , stepButton False
            , pauseButton (model.appState == Pause)
            ]
        , dataRow1 "Max depth" (String.fromInt model.maxDepth)
        , Element.column [ spacing 4 ]
            [ dataRow "Hue" (Quad.lowValueAsString 0 model.colorRange) (Quad.highValueAsString 0 model.colorRange)
            , dataSlider model "HL" (Hue Low)
            , dataSlider model "HH" (Hue High)
            ]
        , Element.column [ spacing 4 ]
            [ dataRow "Saturation" (Quad.lowValueAsString 1 model.colorRange) (Quad.highValueAsString 1 model.colorRange)
            , dataSlider model "SL" (Saturation Low)
            , dataSlider model "SH" (Saturation High)
            ]
        , Element.column [ spacing 4 ]
            [ dataRow "Lightness" (Quad.lowValueAsString 2 model.colorRange) (Quad.highValueAsString 2 model.colorRange)
            , dataSlider model "LL" (Lightness Low)
            , dataSlider model "LH" (Lightness High)
            ]
        , Element.column [ spacing 4 ]
            [ dataRow "Opacity" (Quad.lowValueAsString 3 model.colorRange) (Quad.highValueAsString 3 model.colorRange)
            , dataSlider model "OL" (Opacity Low)
            , dataSlider model "OH" (Opacity High)
            ]
        , Element.column [ spacing 4 ]
            [ dataRow "Proportions H" (Quad.proportionAsString 0 model.proportions) (Quad.proportionAsString 2 model.proportions)
            , dataRow "Proportions V" (Quad.proportionAsString 1 model.proportions) (Quad.proportionAsString 3 model.proportions)
            ]
        , Element.row [ spacing 12, alignBottom, paddingEach { edges | bottom = 24 } ]
            [ Element.el controlLabelStyle (text <| distanceReading model)
            , Element.el controlLabelStyle (text <| sensorReading model)
            ]
        ]


type DataType
    = Hue Position
    | Saturation Position
    | Lightness Position
    | Opacity Position


getValue : Model -> DataType -> Float
getValue model dataType =
    case dataType of
        Hue position ->
            Quad.readColorRangeValue position 0 model.initialColorRange

        Saturation position ->
            Quad.readColorRangeValue position 1 model.colorRange

        Lightness position ->
            Quad.readColorRangeValue position 2 model.colorRange

        Opacity position ->
            Quad.readColorRangeValue position 3 model.colorRange


setValue : Model -> DataType -> Float -> Model
setValue model dataType value =
    let
        newColorRange =
            case dataType of
                Hue position ->
                    Quad.setColorRangeValue position 0 value model.initialColorRange

                Saturation position ->
                    Quad.setColorRangeValue position 1 value model.colorRange

                Lightness position ->
                    Quad.setColorRangeValue position 2 value model.colorRange

                Opacity position ->
                    Quad.setColorRangeValue position 3 value model.colorRange
    in
        { model | initialColorRange = newColorRange, colorRange = newColorRange }


dataSlider : Model -> String -> DataType -> Element Msg
dataSlider model label dataType =
    Input.slider
        [ Element.height (Element.px 20)
        , Element.behindContent
            (Element.el
                [ Element.width (Element.px 210)
                , Element.height (Element.px 2)
                , Element.centerY
                , Background.color <| Element.rgb 0.4 0.4 0.4
                , Border.rounded 2
                ]
                Element.none
            )
        ]
        { onChange = AdjustValue dataType
        , label = Input.labelLeft sliderLabelStyle (text label)
        , min = 0.0
        , max = 1.4
        , step = Nothing
        , value = getValue model dataType
        , thumb =
            Input.defaultThumb
        }


dataRow : String -> String -> String -> Element msg
dataRow label a b =
    Element.row [ spacing 8, Font.color <| Element.rgb 0.7 0.7 0.7 ]
        [ Element.el [ width (px 130) ] (text label)
        , Element.el [ width (px 90) ] (text <| a)
        , Element.el [ width (px 90) ] (text <| b)
        ]


dataRow1 : String -> String -> Element msg
dataRow1 label a =
    Element.row [ spacing 8, Font.color <| Element.rgb 0.7 0.7 0.7 ]
        [ Element.el [ width (px 130) ] (text label)
        , Element.el [ width (px 90) ] (text <| a)
        ]


distanceReading : Model -> String
distanceReading model =
    case model.rawSensorValue of
        Nothing ->
            "Distance: _"

        Just distance ->
            "Distance: " ++ String.fromFloat distance ++ " cm"


sensorReading : Model -> String
sensorReading model =
    case model.sensorValue of
        Nothing ->
            "Sensor: _"

        Just value ->
            "Sensor: " ++ (String.fromFloat (value |> Utility.roundToPlaces 2))


controlLabelStyle =
    [ Font.color <| Element.rgb 0.9 0.9 0.9 ]


sliderLabelStyle =
    [ Font.color <| Element.rgb 0.9 0.9 0.9, Font.size 14, moveDown 5, paddingEach { edges | right = 8 } ]


runButton : Bool -> Element Msg
runButton active =
    Input.button []
        { onPress = Just RunApp
        , label = Element.el (buttonStyle active) (text "Run")
        }


stepButton : Bool -> Element Msg
stepButton active =
    Input.button []
        { onPress = Just Step
        , label = Element.el (buttonStyle active) (text "Step")
        }


pauseButton : Bool -> Element Msg
pauseButton active =
    Input.button []
        { onPress = Just PauseApp
        , label = Element.el (buttonStyle active) (text "Pause")
        }



-- buttonStyle : Bool -> Element.Attribute msg


buttonStyle active =
    case active of
        False ->
            [ Font.color <| Element.rgb 0.8 0.8 0.8
            , Background.color <| Element.rgb 0.2 0.2 0.2
            , padding 8
            ]

        True ->
            [ Font.color <| Element.rgb 0.8 0.8 0.8
            , Background.color <| Element.rgb 0.6 0.2 0.2
            , padding 8
            ]


viewSvg : Model -> Html Msg
viewSvg model =
    let
        currentDrawing =
            if model.depth == 1 then
                model.oldDrawing
            else
                model.drawing
    in
        TypedSvg.svg
            [ TypedSvg.Attributes.width (TypedSvg.Types.px 750), TypedSvg.Attributes.height (TypedSvg.Types.px 750) ]
        <|
            List.map (Quad.render Quad.hsla) currentDrawing


getSensorValue : Cmd Msg
getSensorValue =
    Http.get
        { url = "http:raspberrypi.local:8000/distance"
        , expect = Http.expectString GotSensorValue
        }


ledCommand : Model -> Cmd Msg
ledCommand model =
    case ( model.appState, modBy 2 model.count == 0 ) of
        ( GeneratingImage, True ) ->
            Cmd.batch [ ledOn, led2Off ]

        ( GeneratingImage, False ) ->
            Cmd.batch [ ledOff, led2Off ]

        ( Resting, _ ) ->
            Cmd.batch [ ledOff, led2On ]

        ( Pause, _ ) ->
            Cmd.batch [ ledOff, led2On ]


ledOn : Cmd Msg
ledOn =
    Http.get
        { url = "http:raspberrypi.local:8000/ledOn"
        , expect = Http.expectWhatever SentLedCommand
        }


ledOff : Cmd Msg
ledOff =
    Http.get
        { url = "http:raspberrypi.local:8000/ledOff"
        , expect = Http.expectWhatever SentLedCommand
        }


led2On : Cmd Msg
led2On =
    Http.get
        { url = "http:raspberrypi.local:8000/led2On"
        , expect = Http.expectWhatever SentLed2Command
        }


led2Off : Cmd Msg
led2Off =
    Http.get
        { url = "http:raspberrypi.local:8000/led2Off"
        , expect = Http.expectWhatever SentLed2Command
        }


setColorRange : Maybe Float -> ColorRange -> ColorRange
setColorRange sensorValue colorRange =
    case sensorValue of
        Nothing ->
            colorRange

        Just p ->
            let
                a =
                    0.7 * p |> clamp 0 1

                b =
                    1.3 * p |> clamp 0 1
            in
                ( a, b ) :: (List.drop 1 colorRange)


resetDepth : Maybe Float -> Model -> Int
resetDepth sensorValue model =
    case ( sensorValue, model.sensorValue ) of
        ( Nothing, _ ) ->
            model.depth

        ( Just newSensorValue, Nothing ) ->
            1

        ( Just newSensorValue, Just oldSensorValue ) ->
            case abs (newSensorValue - oldSensorValue) < 0.05 of
                True ->
                    model.depth

                False ->
                    if model.depth == model.maxDepth then
                        1
                    else
                        model.depth
