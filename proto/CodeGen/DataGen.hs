{-# LANGUAGE DataKinds #-}
module CodeGen.DataGen where

import Numeric
import System.IO
import Data.List
import qualified Data.Map as Map
import Data.Ord
import qualified Numeric.LinearAlgebra.HMatrix as M
import GHC.TypeLits
import qualified Data.Vector as V

import CodeGen.BBridgeGen
import CodeGen.Utils
import qualified Config as Conf
import Contract.Date
import Contract
import LexifiContracts

type MarketData = ([Corr], [Quotes])
type SobolDirVects = [String]

data Corr = Corr (String, String) Double
          deriving Show
data Quotes = Quotes String [(Date, Double)]
            deriving Show

data Model = BS String [(Date, Double, Double)]
           deriving Show

data DiscModel = ConstDisc Double 
               | CustomDisc [(Int,Double)]

data ContractMeta = CM
     { underlyings :: [String]
     , startDate   :: Date 
     , obsDates    :: [Date]
     , transfDates :: [Date]
     , allDates    :: [Date] -- observable & transfer dates
     }
     deriving Show

genInput :: DiscModel -> [Model] -> MarketData -> SobolDirVects -> ContractMeta -> [(String,String)]
genInput discM ms md@(corr, quotes) sob cMeta = context
  where
    numDates = length $ allDates cMeta
    numUnder = length $ underlyings cMeta
    summary = genSummary numDates numUnder
    discs = [map (discount discM) $ map (dateDiff (startDate cMeta)) (transfDates cMeta)]
    bbMeta = ppBBMeta $ genBBConf numUnder (startDate cMeta) (allDates cMeta)
    modelData = ppModelData $ prepareModelData ms
    stPrice = show $ [startPrice quotes (startDate cMeta)]
    corrs = ppCorr $ cholesky $ corrMatr corr (underlyings cMeta)
    context = [("SUMMARY", summary), ("DIRVECT", ppDirVects sob),
               ("CORR", corrs), ("MODELDATA", modelData), ("STARTPRICE", stPrice),
               ("DETVALS", inSqBr $ inSqBr "  "), ("DISCOUNTS", show discs), ("BBMETA", bbMeta)]

genSummary numDates numUnder = intercalate "\n" $
                               map show [contrNum, monteCarloIter, numDates,
                                         numUnder, numberOfModels, sobolBitLength] 
  where
    -- some magic numbers from Medium data.
    contrNum = 2
    monteCarloIter = 1048576
    numberOfModels = 1
    sobolBitLength = 30

extractMeta mc@(d,c) = CM { underlyings = observables c
                          , startDate = d
                          , obsDates = oDates
                          , transfDates = tDates
                          , allDates = dates}
  where
    oDates = mObsDates mc
    tDates = mTransfDates mc
    dates = nub $ sort $ oDates ++ tDates

corrMatr cs us = (M.matrix size corrMatr) + M.ident size
  where
    size = length us
    source = cs ++ map permute cs
    ps = [(x,y) | x <- us, y <- us]
    corrMatr = map (f source) ps 
    f xs x = case (find (matchPair x) xs) of
               Just (Corr _ v) -> v
               Nothing -> 0
    matchPair p (Corr p' v) = p == p'
    permute (Corr (u1, u2) v) = Corr (u2,u1) v

cholesky m = cholM + strLTriang
   where
     cholM = M.chol m -- triangular matrix, but we need symmetric matrix ...
     -- making strictly lower triangular matrix (zeros along diagonal)
     -- that we can add to cholM to obtain symmetric one
     strLTriang = M.tr (cholM - (M.diag $ M.takeDiag cholM)) 


prepareModelData md = (vols, drifts)
  where
    sorted = sortBy (comparing (\(BS n _) -> n)) md
    vols = Data.List.transpose $ map (fst . f) sorted
    drifts = Data.List.transpose $ map (snd . f) sorted
    f (BS _ xs) = case (unzip3 xs) of
                  (_, vols, drifts) -> (vols, drifts)

startPrice qs date = map (getPrice date) $ sortBy (comparing (\(Quotes n _) -> n)) qs


getPrice date (Quotes _ qs) = case (find ((== date) . fst) qs) of
                              Just (_,v) -> v
                              Nothing -> error ("No quote for the date " ++ show date)

discount :: DiscModel -> Int -> Double
discount (ConstDisc r) t = exp (-r * yearFraction)
         where
           yearFraction = fromIntegral t / 365

discount (CustomDisc xs) t = (Map.fromList xs) Map.! t

y1980 = at "1980-01-01"
toMinutesFrom1980 :: Date -> Double 
toMinutesFrom1980 d = fromIntegral $ (dateDiff y1980 d) * 24 * 60

datesForBB sd ds = (firstDate, dates)
           where
             firstDate = fromIntegral $ dateDiff y1980 sd * 24 * 60
             dates = map toMinutesFrom1980 ds

genBBConf numUnder startDate dates = bbridgeConf numUnder $ datesForBB startDate dates 

writeInputData context = do
    template <- readFile "./proto/templ/InputTemplate.data"
    writeFile (Conf.genDataPath ++ "input.data") (replaceLabels context template)

genAndWriteData discM modelData marketData contr = 
  do
    fh <- openFile "./proto/CodeGen/sobol_vect.data" ReadMode
    vects <- hGetContents fh
    let cm = extractMeta contr
        sob = take ((length $ underlyings cm) * (length $ allDates cm)) (lines vects)
        res = genInput discM modelData marketData sob cm
    writeInputData res
    hClose fh

-- Pretty-printing data
ppModelData (vols, drifts) = inSqBr (sqBrBlock $ intercalate ",\n" (map (ppList . (map ppDouble')) vols)) ++ "\n\n" ++
                             inSqBr (sqBrBlock $ intercalate ",\n" (map (ppList . (map ppDouble')) drifts))

ppList = inSqBr . commaSeparated 

ppDouble p d = showFFloat (Just p) d ""

ppDouble' = ppDouble 16 

ppDirVects vs = sqBrBlock $ intercalate ",\n" (map inSqBr vs)

ppBBMeta bbMeta = sqBrBlock (intercalate ",\n" (map (show . V.toList) [bb_bi bbMeta, bb_li bbMeta, bb_ri bbMeta])) ++ "\n\n"
                  ++ sqBrBlock (intercalate ",\n" (map (show . V.toList) [bb_sd bbMeta, bb_lw bbMeta, bb_rw bbMeta]))

ppCorr corrM = inSqBr $ sqBrBlock (intercalate ",\n" $ map (ppList . map (ppDouble 7)) $ M.toLists corrM)

sqBrBlock = inSqBr . surroundBy "\n"

