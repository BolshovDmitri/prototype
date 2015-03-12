{-# LANGUAGE GADTs, DeriveGeneric, FlexibleInstances, FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings, StandaloneDeriving #-}
module Service where

import View
import Pricing (runPricing)
import DataProviders.Data
import DataProviders.Common
import CodeGen.DataGen hiding (startDate)
import Contract.Expr
import Contract.Type
import Contract.Environment
import Contract.Transform
import TypeClass
import Data
import PersistentData
import DB
import Serialization
import Utils
import CodeGen.Utils

import Web.Scotty hiding (body, params)
import Web.Scotty.Internal.Types hiding (Env)
import Network.Wai.Middleware.Static (staticPolicy, addBase)
import CSS
import Data.Aeson (object, (.=), FromJSON(..), decode, eitherDecode, Value (..), encode)
import Control.Monad.Trans
import qualified Data.Map as M
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString as W
import Data.Word
import GHC.Generics
import Data.Data
import qualified Data.Text.Lazy as TL
import qualified Data.Text as T
import qualified Database.Persist as P
import Database.Persist.Sql (toSqlKey, fromSqlKey)
import Data.Time (Day, diffDays)
import Data.Text (Text)
import Data.Maybe

instance FromJSON CommonContractData
instance FromJSON PricingForm
instance FromJSON DataForm

defaultService allContracts dataProvider = do
    get "/" $ homeView allContracts
    get (capture $ contractsBaseUrl ++ ":type") $ do
                       ty <- param "type"
                       contractView allContracts (toMap allContracts M.! ty)
    post "/pricer/" $ do
      pricingForm <- (jsonParam "conf") :: ActionM PricingForm
      pItems <- liftIO ((runDb $ P.selectList [] []) :: IO [P.Entity PFItem])
      res <- liftIO $ mapM (maybeValuate pricingForm dataProvider) $ map P.entityVal pItems
      json $ object [ "prices" .= res
                    , "total"  .= (sum $ map (fromMaybe 0) res) ]
    get "/portfolio/" $ do
      pItems <- liftIO ((runDb $ P.selectList [] []) :: IO [P.Entity PFItem])
      portfolioView $ map fromEntity pItems
    delete "/portfolio/:id" $ do
      pfiId <- param "id"
      let key = toSqlKey (fromIntegral ((read pfiId) :: Integer)) :: P.Key PFItem
      liftIO $ runDb $ P.delete key
      text "OK"
    get "/marketData/underlyings/" $ do
      availUnd <- liftIO (storedUnderlyings dataProvider)
      json availUnd
    get "/marketData/view/" $ do 
      quotes <- liftIO $ storedQuotes dataProvider
      marketDataView quotes
    post "/marketData/" $ do
      form <- jsonData :: ActionM DataForm
      let md = DbQuotes (fUnderlying form) (fDate form) (fVal form)
      liftIO $ runDb $ P.insert_ md
      json $ object ["msg" .= ("Data added successfully" :: String)]
    delete "/marketData/" $ do
      key <- jsonData :: ActionM (Text, Day)
      liftIO $ runDb $ P.deleteBy $ (uncurry QuoteEntry) key
      text "OK"
    get "/modelData/" $ do
      md <- liftIO $ storedModelData dataProvider
      modelDataView md
    post   "/modelData/" $ do
      form <- jsonData :: ActionM DataForm
      let md = DbModelData (fUnderlying form) (fDate form) (fVal form)
      liftIO $ runDb $ P.insert_ md
      json $ object ["msg" .= ("Data added successfully" :: String)]
    delete "/modelData/" $ do
      key <- jsonData :: ActionM (Text, Day)
      liftIO $ runDb $ P.deleteBy $ (uncurry MDEntry) key
      text "OK"
    middleware $ staticPolicy (addBase "src/Web/static")

api contractType inputData mkContr = 
    post (literal ("/api/" ++ contractType)) $
         do
           commonData <- (jsonParam "common" :: ActionM CommonContractData)
           contractData <- inputData 
           pItems <- liftIO $ runDb $ P.insert $ toPFItem commonData contractData $ mkContr (startDate commonData) contractData
           json $ object ["msg" .= ("Contract added successfully" :: String)]

toMap = M.fromList . map (\c -> (url c, c))

-- Parse contents of parameter p as a JSON object and return it. Raises an exception if parse is unsuccessful.
jsonParam p = do
  b <- param p
  either (\e -> raise $ stringError $ "jsonData - no parse: " ++ e ++ ". Data was:" ++ BL.unpack b) return $ eitherDecode b

jsonContract :: (FromJSON a) => ActionM a
jsonContract = jsonParam ("contractData" :: TL.Text)

toPFItem commonData cInput cs = PFItem { pFItemStartDate = startDate commonData
                                       , pFItemContractType = TL.toStrict $ TL.pack $ show $ typeOf cInput
                                       , pFItemNominal = nominal commonData
                                       , pFItemContractSpec = T.pack $ show cs }

makeInput :: MContract -> PricingForm -> DataProvider -> IO ((DiscModel, [Model], MarketData), MContract)
makeInput mContr@(sDate, contr) pricingForm dataProvider = do
  (modelData, marketData) <- mkData mContr pricingForm dataProvider
  return ( (ConstDisc $ interestRate pricingForm
           , modelData
           , marketData) 
         , mContr)
    where
      currDate = fromMaybe (contrDate2Day sDate) $ currentDate pricingForm 
      dt = fromIntegral $ diffDays currDate $ contrDate2Day sDate
      cMeta = extractMeta mContr
      allDays = map contrDate2Day (allDates cMeta)

mkData mContr@(sDate, contr) pricingForm dataProvider = do
  rawModelData <- mapM (getRawModelData allDays) unds
  rawQuotes <- mapM (getRawQuotes $ (contrDate2Day sDate) : allDays) unds
  return ( map toBS $ zip unds $ rawModelData
         , toMarketData $ (concat rawQuotes, [])) -- ingnoring correlations for now
    where
      toBS (und, md) = bsRiskFreeRate und (map convertDate md) (interestRate pricingForm) sDate eDate
      cMeta = extractMeta mContr
      eDate = endDate cMeta
      unds  = underlyings cMeta
      allDays = map contrDate2Day (allDates cMeta)
      getRawModelData = provideModelData dataProvider
      getRawQuotes = provideQuotes dataProvider
      convertDate (u, d, v) = (u, day2ContrDate d, v)

makeEnv quotes = foldr (.) id $ map f quotes
    where
      f (und, d, q) = addFixing (und, day2ContrDate d, q)

maybeValuate :: PricingForm -> DataProvider -> PFItem -> IO (Maybe Double)
maybeValuate pricingForm dataProvider portfItem = if (dt >= 0) then
                                                      do v <- valuate pricingForm dataProvider portfItem
                                                         return $ Just v
                                                  else return Nothing
    where
      currDate = fromMaybe (pFItemStartDate portfItem) $ currentDate pricingForm
      dt = fromIntegral $ diffDays currDate $ pFItemStartDate portfItem

valuate pricingForm dataProvider portfItem = do
  quotesBefore <- mapM (getRawQuotes $ sDate : filter (<= currDate) allDays) unds
  let env = (makeEnv (concat quotesBefore)) $ emptyFrom $ day2ContrDate sDate
      simplContr = advance dt $ simplify env mContr
  (inp, contr) <- makeInput simplContr pricingForm dataProvider
  let iter = DataConf { monteCarloIter =  (iterations pricingForm) }
      nominal_ = (fromIntegral (pFItemNominal portfItem))
  [val] <- runPricing iter [inp] contr
  return $  nominal_ * val
  where
    currDate = fromMaybe sDate $ currentDate pricingForm 
    dt = fromIntegral $ diffDays currDate sDate
    sDate = pFItemStartDate portfItem
    mZero = (day2ContrDate sDate, zero)
    mContr = (day2ContrDate sDate, read $ T.unpack $ pFItemContractSpec portfItem)
    cMeta = extractMeta mContr
    allDays = map contrDate2Day (allDates cMeta)
    unds  = underlyings cMeta      
    getRawQuotes = provideQuotes dataProvider

fromEntity p = (show $ fromSqlKey $ P.entityKey p, P.entityVal p)
