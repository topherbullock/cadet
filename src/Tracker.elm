module Tracker exposing
  ( APIError
  , Error
  , Story
  , Iteration
  , StoryType(..)
  , StoryState(..)
  , fetchProjectStories
  , fetchProjectBacklog
  , startStory
  , finishStory
  , acceptStory
  , deleteStory
  , storyIsScheduled
  , storyIsInFlight
  , storyIsAccepted
  , compareStoryProgress
  , compareProgress
  )

import Dict exposing (Dict)
import Http
import HttpBuilder
import Json.Decode exposing ((:=))
import String
import Task exposing (Task)

import Pagination

type alias Token = String

type alias APIError =
  { code : String
  , error : String
  , requirement : Maybe String
  , general_problem : Maybe String
  , possible_fix : Maybe String
  , validation_errors : Maybe (List String)
  }

type alias Error =
  HttpBuilder.Error APIError

type alias Story =
  { id : Int
  , url : String
  , summary : String
  , type' : StoryType
  , estimate : Maybe Int
  , state : StoryState
  , labels : List String
  }

type alias Iteration =
  { number : Int
  , stories : List Story
  }

type StoryType
  = StoryTypeChore
  | StoryTypeFeature
  | StoryTypeBug
  | StoryTypeRelease

type StoryState
  = StoryStateUnscheduled
  | StoryStateUnstarted
  | StoryStateStarted
  | StoryStateFinished
  | StoryStateDelivered
  | StoryStateAccepted
  | StoryStateRejected

fetchProjectStories : Token -> Int -> Task Http.Error (List Story)
fetchProjectStories token project =
  Pagination.fetchAll
    ("https://www.pivotaltracker.com/services/v5/projects/" ++ toString project ++ "/stories?envelope=true")
    [("X-TrackerToken", token)]
    (trackerPagination decodeStory)
    Nothing

fetchProjectBacklog : Token -> Int -> Task Http.Error (List Iteration)
fetchProjectBacklog token project =
  Pagination.fetchAll
    ("https://www.pivotaltracker.com/services/v5/projects/" ++ toString project ++ "/iterations?envelope=true&scope=current_backlog")
    [("X-TrackerToken", token)]
    (trackerPagination decodeIteration)
    Nothing

startStory : Token -> Int -> Int -> Task Error Story
startStory token project story =
  updateStory token project story "{\"current_state\":\"started\"}"

finishStory : Token -> Int -> Int -> Task Error Story
finishStory token project story =
  updateStory token project story "{\"current_state\":\"finished\"}"

acceptStory : Token -> Int -> Int -> Task Error Story
acceptStory token project story =
  updateStory token project story "{\"current_state\":\"accepted\"}"

deleteStory : Token -> Int -> Int -> Task Error ()
deleteStory token project story =
  HttpBuilder.delete ("https://www.pivotaltracker.com/services/v5/projects/" ++ toString project ++ "/stories/" ++ toString story)
    |> HttpBuilder.withHeader "X-TrackerToken" token
    |> HttpBuilder.send (always (Ok ())) (HttpBuilder.jsonReader decodeError)
    |> Task.map .data

updateStory : Token -> Int -> Int -> String -> Task Error Story
updateStory token project story payload =
  HttpBuilder.put ("https://www.pivotaltracker.com/services/v5/projects/" ++ toString project ++ "/stories/" ++ toString story)
    |> HttpBuilder.withHeader "Content-Type" "application/json"
    |> HttpBuilder.withHeader "X-TrackerToken" token
    |> HttpBuilder.withBody (Http.string payload)
    |> HttpBuilder.send (HttpBuilder.jsonReader decodeStory) (HttpBuilder.jsonReader decodeError)
    |> Task.map .data


storyIsScheduled : Story -> Bool
storyIsScheduled {state} =
  state /= StoryStateUnscheduled

storyIsInFlight : Story -> Bool
storyIsInFlight {state} =
  case state of
    StoryStateUnscheduled ->
      False
    StoryStateUnstarted ->
      False
    StoryStateStarted ->
      True
    StoryStateFinished ->
      True
    StoryStateDelivered ->
      True
    StoryStateAccepted ->
      False
    StoryStateRejected ->
      True

storyIsAccepted : Story -> Bool
storyIsAccepted {state} =
  case state of
    StoryStateAccepted ->
      True

    _ ->
      False

decodeError : Json.Decode.Decoder APIError
decodeError =
  Json.Decode.object6 APIError
    ("code" := Json.Decode.string)
    ("error" := Json.Decode.string)
    (Json.Decode.maybe ("requirement" := Json.Decode.string))
    (Json.Decode.maybe ("general_problem" := Json.Decode.string))
    (Json.Decode.maybe ("possible_fix" := Json.Decode.string))
    (Json.Decode.maybe ("validation_errors" := Json.Decode.list Json.Decode.string))

decodeStory : Json.Decode.Decoder Story
decodeStory =
  Json.Decode.object7 Story
    ("id" := Json.Decode.int)
    ("url" := Json.Decode.string)
    ("name" := Json.Decode.string)
    ("story_type" := decodeStoryType)
    (Json.Decode.maybe ("estimate" := Json.Decode.int))
    ("current_state" := decodeStoryState)
    ("labels" := Json.Decode.list ("name" := Json.Decode.string))

decodeIteration : Json.Decode.Decoder Iteration
decodeIteration =
  Json.Decode.object2 Iteration
    ("number" := Json.Decode.int)
    ("stories" := Json.Decode.list decodeStory)

decodeStoryType : Json.Decode.Decoder StoryType
decodeStoryType =
  Json.Decode.customDecoder Json.Decode.string <| \x ->
    case x of
      "chore" ->
        Ok StoryTypeChore
      "feature" ->
        Ok StoryTypeFeature
      "bug" ->
        Ok StoryTypeBug
      "release" ->
        Ok StoryTypeRelease
      _ ->
        Err ("unknown story type: " ++ x)

decodeStoryState : Json.Decode.Decoder StoryState
decodeStoryState =
  Json.Decode.customDecoder Json.Decode.string <| \x ->
    case x of
      "unscheduled" ->
        Ok StoryStateUnscheduled
      "unstarted" ->
        Ok StoryStateUnstarted
      "started" ->
        Ok StoryStateStarted
      "finished" ->
        Ok StoryStateFinished
      "delivered" ->
        Ok StoryStateDelivered
      "accepted" ->
        Ok StoryStateAccepted
      "rejected" ->
        Ok StoryStateRejected
      _ ->
        Err ("unknown story state: " ++ x)

type Page = Offset Int

trackerPagination : Json.Decode.Decoder a -> Pagination.Strategy Page a
trackerPagination decode =
  { onPage = \page request ->
      { request | url = addParams request.url page }

  , nextPage = \response ->
      case response.value of
        Http.Text body ->
          let
            rtotal =
              Json.Decode.decodeString (Json.Decode.at ["pagination", "total"] Json.Decode.int) body

            roffset =
              Json.Decode.decodeString (Json.Decode.at ["pagination", "offset"] Json.Decode.int) body

            rreturned =
              Json.Decode.decodeString (Json.Decode.at ["pagination", "returned"] Json.Decode.int) body
          in
            case (rtotal, roffset, rreturned) of
              (Ok total, Ok offset, Ok returned) ->
                if offset + returned < total
                  then Just (Offset (offset + returned))
                  else Nothing

              _ ->
                Nothing
        Http.Blob _ ->
          Nothing

  , previousPage =
      always Nothing

  , content =
      ("data" := Json.Decode.list decode)
  }

addParams : String -> Page -> String
addParams url page =
  let
    (baseURL, query) = extractQuery url
  in
    setQuery baseURL (Dict.union query (toQuery page))

extractQuery : String -> (String, Dict String String)
extractQuery url =
  case String.split "?" url of
    baseURL :: query :: _ ->
      (baseURL, parseQuery query)

    _ ->
      (url, Dict.empty)

setQuery : String -> Dict String String -> String
setQuery baseURL query =
  let
    params =
      String.join "&" <|
        List.map (\(k, v) -> k ++ "=" ++ v) (Dict.toList query)
  in
    if params == "" then
      baseURL
    else
      baseURL ++ "?" ++ params

parseQuery : String -> Dict String String
parseQuery query =
  let
    parseParam p =
      case String.split "=" p of
        k :: vs ->
          (k, String.join "=" vs)

        [] ->
          ("", "")
  in
    Dict.fromList <|
      List.map parseParam <|
        String.split "&" query

toQuery : Page -> Dict String String
toQuery (Offset offset) =
  Dict.singleton "offset" (toString offset)

compareStoryProgress : Story -> Story -> Order
compareStoryProgress a b =
  compareProgress a.state b.state

compareProgress : StoryState -> StoryState -> Order
compareProgress a b =
  if a == b then
    EQ
  else
    case (a, b) of
      (StoryStateUnscheduled, _) ->
        LT

      (StoryStateUnstarted, StoryStateUnscheduled) ->
        GT
      (StoryStateUnstarted, _) ->
        LT

      (StoryStateStarted, StoryStateUnscheduled) ->
        GT
      (StoryStateStarted, StoryStateUnstarted) ->
        GT
      (StoryStateStarted, _) ->
        LT

      (StoryStateFinished, StoryStateUnscheduled) ->
        GT
      (StoryStateFinished, StoryStateUnstarted) ->
        GT
      (StoryStateFinished, StoryStateStarted) ->
        GT
      (StoryStateFinished, _) ->
        LT

      (StoryStateDelivered, StoryStateUnscheduled) ->
        GT
      (StoryStateDelivered, StoryStateUnstarted) ->
        GT
      (StoryStateDelivered, StoryStateStarted) ->
        GT
      (StoryStateDelivered, StoryStateFinished) ->
        GT
      (StoryStateDelivered, _) ->
        LT

      (StoryStateAccepted, StoryStateRejected) ->
        EQ
      (StoryStateRejected, StoryStateAccepted) ->
        EQ

      (StoryStateAccepted, StoryStateUnscheduled) ->
        GT
      (StoryStateAccepted, StoryStateUnstarted) ->
        GT
      (StoryStateAccepted, StoryStateStarted) ->
        GT
      (StoryStateAccepted, StoryStateFinished) ->
        GT
      (StoryStateAccepted, StoryStateDelivered) ->
        GT
      (StoryStateAccepted, _) ->
        LT

      (StoryStateRejected, StoryStateUnscheduled) ->
        GT
      (StoryStateRejected, StoryStateUnstarted) ->
        GT
      (StoryStateRejected, StoryStateStarted) ->
        GT
      (StoryStateRejected, StoryStateFinished) ->
        GT
      (StoryStateRejected, StoryStateDelivered) ->
        GT
      (StoryStateRejected, _) ->
        LT
