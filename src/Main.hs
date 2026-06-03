{-
  Payment Webhook Service
  Programação Funcional — Aula 24 — Insper 2025-1

  Princípios funcionais aplicados:
  - Funções puras para todas as validações
  - Tipos algébricos (ADTs) para representar resultado de validação
  - Pipeline com composição de funções (foldr)
  - Efeitos colaterais isolados na IO monad
  - Imutabilidade: STM TVar para estado compartilhado thread-safe
-}

{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent.STM         (TVar, atomically, newTVarIO,
                                                  modifyTVar', readTVar)
import           Control.Monad                  (when)
import           Data.Aeson                     (FromJSON, decode, encode,
                                                  object, parseJSON, withObject,
                                                  (.:), (.=))
import qualified Data.Aeson.Key                 as K
import qualified Data.ByteString                as BS
import qualified Data.ByteString.Lazy           as LBS
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as TE
import           Network.HTTP.Conduit           (RequestBody (..), httpLbs,
                                                  method, newManager,
                                                  parseRequest,
                                                  requestBody,
                                                  requestHeaders,
                                                  tlsManagerSettings)
import           Network.HTTP.Types             (Status, status200, status400,
                                                  status403)
import           Network.Wai                    (Application, Request,
                                                  responseLBS, strictRequestBody)
import qualified Network.Wai                    as Wai
import           Network.Wai.Handler.Warp       (run)


-- ---------------------------------------------------------------------------
-- Tipos de domínio
-- ---------------------------------------------------------------------------

data WebhookPayload = WebhookPayload
  { wpEvent         :: Text
  , wpTransactionId :: Text
  , wpAmount        :: Text
  , wpCurrency      :: Text
  , wpTimestamp     :: Text
  } deriving (Show, Eq)

instance FromJSON WebhookPayload where
  parseJSON = withObject "WebhookPayload" $ \o ->
    WebhookPayload
      <$> o .: "event"
      <*> o .: "transaction_id"
      <*> o .: "amount"
      <*> o .: "currency"
      <*> o .: "timestamp"

-- Resultado de cada etapa de validação
data ValidationResult
  = Valid
  | InvalidNoCancel Status Text
  | InvalidCancel   Status Text
  deriving (Show, Eq)

-- Contexto imutável que flui pelo pipeline
data Context = Context
  { ctxToken   :: Maybe Text
  , ctxPayload :: Maybe WebhookPayload
  } deriving (Show)


-- ---------------------------------------------------------------------------
-- Configuração
-- ---------------------------------------------------------------------------

secretToken :: Text
secretToken = "meu-token-secreto"

expectedAmount :: Text
expectedAmount = "49.90"

expectedCurrency :: Text
expectedCurrency = "BRL"

gatewayUrl :: String
gatewayUrl = "http://127.0.0.1:5001"


-- ---------------------------------------------------------------------------
-- Funções puras de validação
-- ---------------------------------------------------------------------------

validateToken :: Context -> ValidationResult
validateToken ctx =
  case ctxToken ctx of
    Just t | t == secretToken -> Valid
    _ -> InvalidNoCancel status403 "invalid token"

validatePayload :: Context -> ValidationResult
validatePayload ctx =
  case ctxPayload ctx of
    Just _  -> Valid
    Nothing -> InvalidNoCancel status400 "invalid payload"

validateRequiredFields :: Context -> ValidationResult
validateRequiredFields ctx =
  case ctxPayload ctx of
    Nothing -> InvalidNoCancel status400 "invalid payload"
    Just _  -> Valid

validateNotDuplicate :: Set.Set Text -> Context -> ValidationResult
validateNotDuplicate confirmed ctx =
  case ctxPayload ctx of
    Nothing -> InvalidNoCancel status400 "invalid payload"
    Just p  ->
      if Set.member (wpTransactionId p) confirmed
        then InvalidCancel status400 "transaction duplicated"
        else Valid

validateOrderValues :: Context -> ValidationResult
validateOrderValues ctx =
  case ctxPayload ctx of
    Nothing -> InvalidNoCancel status400 "invalid payload"
    Just p  ->
      if wpAmount p == expectedAmount && wpCurrency p == expectedCurrency
        then Valid
        else InvalidCancel status400 "mismatch"


-- ---------------------------------------------------------------------------
-- Pipeline funcional com foldr
-- ---------------------------------------------------------------------------

type Validator = Context -> ValidationResult

runPipeline :: [Validator] -> Context -> ValidationResult
runPipeline validators ctx =
  foldr step Valid validators
  where
    step _         (InvalidNoCancel s r) = InvalidNoCancel s r
    step _         (InvalidCancel   s r) = InvalidCancel   s r
    step validator Valid                 = validator ctx


-- ---------------------------------------------------------------------------
-- Respostas JSON puras
-- ---------------------------------------------------------------------------

successResponse :: Text -> LBS.ByteString
successResponse txId = encode $ object
  [ "status"         .= ("confirmed" :: Text)
  , "transaction_id" .= txId
  ]

errorResponse :: Text -> Text -> LBS.ByteString
errorResponse st reason = encode $ object
  [ "status" .= st
  , "reason" .= reason
  ]

errorResponseWithTx :: Text -> Text -> Text -> LBS.ByteString
errorResponseWithTx st txId reason = encode $ object
  [ "status"         .= st
  , "transaction_id" .= txId
  , "reason"         .= reason
  ]


-- ---------------------------------------------------------------------------
-- Efeitos colaterais: comunicação com gateway
-- ---------------------------------------------------------------------------

postToGateway :: String -> Text -> IO ()
postToGateway endpoint txId = do
  manager  <- newManager tlsManagerSettings
  initReq  <- parseRequest (gatewayUrl <> "/" <> endpoint)
  let body = encode $ object ["transaction_id" .= txId]
      req  = initReq
               { method          = "POST"
               , Network.HTTP.Conduit.requestBody    = RequestBodyLBS body
               , Network.HTTP.Conduit.requestHeaders =
                   [("Content-Type", "application/json")]
               }
  _ <- httpLbs req manager
  return ()

cancelTransaction :: Text -> IO ()
cancelTransaction = postToGateway "cancelar"

confirmTransaction :: TVar (Set.Set Text) -> Text -> IO ()
confirmTransaction confirmedVar txId = do
  atomically $ modifyTVar' confirmedVar (Set.insert txId)
  postToGateway "confirmar" txId


-- ---------------------------------------------------------------------------
-- Helpers de leitura
-- ---------------------------------------------------------------------------

extractToken :: Request -> Maybe Text
extractToken req =
  fmap TE.decodeUtf8
  . lookup "x-webhook-token"
  $ Wai.requestHeaders req

parseBody :: LBS.ByteString -> Maybe WebhookPayload
parseBody = decode


-- ---------------------------------------------------------------------------
-- Aplicação WAI
-- ---------------------------------------------------------------------------

app :: TVar (Set.Set Text) -> Application
app confirmedVar req respond = do
  body <- strictRequestBody req
  let token   = extractToken req
      payload = parseBody body
      ctx     = Context token payload

  confirmed <- atomically $ readTVar confirmedVar

  let preValidators  = [validateToken, validatePayload, validateRequiredFields]
      postValidators = [validateNotDuplicate confirmed, validateOrderValues]

  let preResult = runPipeline preValidators ctx

  case preResult of
    InvalidNoCancel s reason ->
      respond $ responseLBS s [("Content-Type", "application/json")]
        (errorResponse "cancelled" reason)

    _ -> do
      let postResult = runPipeline postValidators ctx
      case (postResult, payload) of
        (InvalidCancel s reason, Just p) -> do
          cancelTransaction (wpTransactionId p)
          respond $ responseLBS s [("Content-Type", "application/json")]
            (errorResponseWithTx "cancelled" (wpTransactionId p) reason)

        (InvalidCancel s reason, Nothing) ->
          respond $ responseLBS s [("Content-Type", "application/json")]
            (errorResponse "cancelled" reason)

        (InvalidNoCancel s reason, _) ->
          respond $ responseLBS s [("Content-Type", "application/json")]
            (errorResponse "cancelled" reason)

        (Valid, Just p) -> do
          confirmTransaction confirmedVar (wpTransactionId p)
          respond $ responseLBS status200 [("Content-Type", "application/json")]
            (successResponse (wpTransactionId p))

        (Valid, Nothing) ->
          respond $ responseLBS status400 [("Content-Type", "application/json")]
            (errorResponse "cancelled" "invalid payload")


-- ---------------------------------------------------------------------------
-- Entrypoint
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  confirmedVar <- newTVarIO Set.empty
  putStrLn "Webhook server running on http://127.0.0.1:5000"
  run 5000 (app confirmedVar)
