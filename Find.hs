{-# LANGUAGE FlexibleContexts #-}

module Find (
  Rel, ItemQualAttr(..), ItemQual(..), Find(..),
  makeTree, 
  ItemSource(..), Item(..),
  find )
where

import Control.Applicative ((<$>), (<*>))
import Data.Maybe
import Data.NBT
import Game.Minecraft.Level
import Game.Minecraft.Identifiers
import Text.Parsec.Prim
import Text.ParserCombinators.Parsec
import Text.Printf
import GHC.Int

type Rel = Int -> Bool
    
data ItemQualAttr = ItemQualLevel Rel

data ItemQual = 
  ItemQualEnch {
    itemQualEnchId :: Int, 
    itemQualEnchAttrs :: [ItemQualAttr] }

data Find = FindItem { 
  findItemId :: Maybe Int,
  findItemQuals :: [ItemQual] } 

parseNumber :: Parser Int
parseNumber = fmap read (many1 digit)

parseId :: Parser Int
parseId = char '=' >> parseNumber

type BRel = Int -> Int -> Bool

parseRelLT :: Parser BRel
parseRelLT = string "<" >> return (<)

parseRelLE :: Parser BRel
parseRelLE = string "<=" >> return (<=)

parseRelEQ :: Parser BRel
parseRelEQ = string "=" >> return (==)

parseRelGE :: Parser BRel
parseRelGE = string ">=" >> return (>=)

parseRelGT :: Parser BRel
parseRelGT = string ">" >> return (>)

parseRel :: Parser Rel
parseRel = do
  rel <- parseRelLT <|> parseRelLE <|> parseRelEQ <|> parseRelGE <|> parseRelGT
  val <- parseNumber
  return $ (`rel` val)

parseItemLevel :: Parser ItemQualAttr
parseItemLevel = do
  _ <- string "level"
  rel <- parseRel
  return $ ItemQualLevel rel

parseList :: Stream s m Char => ParsecT s u m a -> ParsecT s u m [a]
parseList parseElem = 
  between (char '[') (char ']') (sepBy1 parseElem (char ','))

parseItemEnch :: Parser ItemQual
parseItemEnch = do
  _ <- string "ench"
  val <- parseId
  quals <- option [] $ parseList parseItemLevel
  return $ ItemQualEnch {
    itemQualEnchId = val, 
    itemQualEnchAttrs = quals }

parseItem :: Parser Find
parseItem = do
  _ <- string "item"
  maybeItemId <- optionMaybe parseId
  quals <- option [] (parseList parseItemEnch)
  return $ FindItem { 
    findItemId = maybeItemId, 
    findItemQuals = quals }

parseExpr :: Parser Find
parseExpr = do
  findExpr <- parseItem
  eof
  return findExpr

makeTree :: String -> Find
makeTree expr =
  case parse parseExpr "find-expr" expr of
    Left msg -> error $ show msg
    Right t -> t


data ItemSource = ItemSourcePlayer {ispName :: String}
                | ItemSourceTile {istDim :: String}
                | ItemSourceFree {isfDim :: String}
                | ItemSourceContained {istContainer :: String}

instance Show ItemSource where
  show (ItemSourceFree dim) = "free[dim=" ++ dim ++ "]"
  show (ItemSourcePlayer name) = "player[name=" ++ name ++ "]"
  show (ItemSourceTile dim ) = "tile[dim=" ++ dim ++ "]"
  show (ItemSourceContained container) = "inside[tile=" ++ container ++ "]"

data Item = Item {
  itemCoords :: (Int, Int, Int),
  itemSource :: ItemSource,
  itemData :: NBT}

data ItemEnchantment = ItemEnchantment {
    enchantmentId :: Int,
    enchantmentLevel :: Int
}


extractItemDescription :: Item -> String
extractItemDescription item =
    extractItemIdWithResult (itemSource item) (itemData item) (\x-> itemIdToName (fromIntegral x)) (\x->x)
    
extractItemId :: Item -> Int
extractItemId item =
    extractItemIdWithResult (itemSource item) (itemData item) fromIntegral (\_-> -1)

extractItemIdWithResult :: ItemSource -> NBT -> (GHC.Int.Int16 -> t) -> (String -> t) -> t
extractItemIdWithResult source nbt valueFunc stringFunc =
    case source of
        ItemSourceFree _ -> findValue(path [Nothing, Just "Item", Just "id"] nbt)
        _ -> findValue(path [Nothing, Just "id"] nbt)
    where
        findValue (Just (ShortTag (Just "id") i)) = valueFunc i
        findValue (Just (StringTag (Just "id") _ z)) = stringFunc z
        findValue _ = error "item without id"

extractTileItemId :: NBT -> String
extractTileItemId nbt =
    case path [Nothing, Just "id"] nbt of
        Just (StringTag (Just "id") _ tileId) -> tileId
        _ -> ""

extractContainedItems :: Item -> [Item]
extractContainedItems Item {itemCoords = (x, y, z), itemData = nbt} = 
    case path [Nothing, Just "Items"] nbt of
        Just (ListTag (Just "Items") _ _ inneritems) ->
            (map constructContainedItem inneritems)
        _ -> []
    where
        constructContainedItem innerItem= 
            Item {
              itemCoords = (x,y,z),
              itemSource = ItemSourceContained (extractTileItemId nbt),
              itemData = innerItem}

extractEnchantments :: Item -> [ItemEnchantment]
extractEnchantments Item {itemData = nbt} =
    case path [Nothing, Just "Item", Just "tag", Just "ench"] nbt of
        Just (ListTag (Just "ench") _ _ inneritems) ->
            (mapMaybe constructEnchantment inneritems)
        _ -> case path [Nothing, Just "tag", Just "ench"] nbt of
                Just (ListTag (Just "ench") _ _ inneritems) ->
                    (mapMaybe constructEnchantment inneritems)
                _ -> []
    where
        constructEnchantment CompoundTag {compoundTag = [ShortTag {tagName = Just "id", shortTag = enchId},
                                                         ShortTag {tagName = Just "lvl", shortTag = enchLvl}]} = 
            Just ItemEnchantment {
                enchantmentId = fromIntegral enchId,
                enchantmentLevel = fromIntegral enchLvl
            }
        constructEnchantment _ = Nothing
        
instance Show Item where
  show item =
        let containedItems = extractContainedItems item in
        if null containedItems && null (extractEnchantments item) then
            printf "item=%s[x=%d,y=%d,z=%d,source=%s]" 
                                (extractItemDescription item) x y z (show (itemSource item))
        else if null containedItems then
            printf "item=%s[x=%d,y=%d,z=%d,source=%s,enchantments=%s]" 
                                (extractItemDescription item) x y z (show (itemSource item)) (show (extractEnchantments item))
        else if null (extractEnchantments item) then
            printf "item=%s[x=%d,y=%d,z=%d,source=%s\ncontainedItems=\n%s]" 
                                (extractItemDescription item) x y z (show (itemSource item))  
                                    (unlines (map (\i-> "  " ++ show i) (containedItems)))
        else
            printf "item=%s[x=%d,y=%d,z=%d,source=%s,enchantments=%s\ncontainedItems=\n%s]" 
                                (extractItemDescription item) x y z (show (itemSource item)) (show (extractEnchantments item))
                                    (unlines (map (\i-> "  " ++ show i) (containedItems)))
        where
            (x,y,z) = (itemCoords item)

instance Show ItemEnchantment where
    show ench =
        printf "%s[level=%d]" (enchIdToName (enchantmentId ench)) (enchantmentLevel ench)

    
{-   itemTags =
        concat $ mapMaybe (fmap (',' :) . showTag) $ 
          fromJust $ contents $ Just nbt
        where
          showTag (CompoundTag (Just "tag") nbts)
            decodeTag nbts
            where 
              decodeTag nbts@(ListTag (Just "ench") CompoundType _ _) =
                let enchId =
                      case path [Just "ench", Just "id"] nbt of
                        Just (ShortTag (Just "id") i) -> i
                        _ -> error "ench without id" 
                    enchLevel =
                      case path [Just "ench", Just "lvl"] nbt of
                        Just (ShortTag (Just "lvl") i) -> i
                        _ -> error "ench without lvl"
                in
                Just $ printf "ench=%d[level=%d]" enchId enchLevel
              decodeTag _ = Nothing 
          showTag _ = Nothing -}

path :: [Maybe String] -> NBT -> Maybe NBT
path [p] nbt | p == tagName nbt =
  Just nbt
path (p : ps) (CompoundTag t nbts) | p == t =
  tryRest ps nbts
path (p : ps) (ListTag t _ _ nbts) | p == t =
  tryRest ps nbts
path _ _ = Nothing

tryRest :: [Maybe String] -> [NBT] -> Maybe NBT
tryRest ps nbts =
  case mapMaybe (path ps) nbts of
    [nbt] -> Just nbt
    _ -> Nothing

globalCoords :: NBT -> Region -> ChunkData -> (Int, Int, Int)
globalCoords ent region chunk =
    case path [Nothing, Just "Pos"] ent of
      Just (ListTag _  DoubleType _ [ 
               DoubleTag Nothing x, 
               DoubleTag Nothing y, 
               DoubleTag Nothing z ]) -> getCoords (floor x) (floor y) (floor z)
      _ -> getCoords (getValue "x") (getValue "y") (getValue "z")
    where
        getCoords x y z = 
            let (rx, rz) = regionPos region in
            let (cx, cz) = ciPos $ 
                           cdChunkIndex chunk in
            (mcc rx cx x, 
             y, 
             mcc rz cz z)
            where
              mcc r c b =
                b + 16 * (c + 32 * r)
        getValue val =
            case path [Nothing, Just val] ent of
                Just (IntTag _ intVal) -> fromIntegral intVal
                _ -> 0

filterById :: Find -> Item -> Bool
filterById tree item  = 
    case (findItemId tree) of
        Just itemId -> (itemId == extractItemId item) ||
                       any  (filterById tree) (extractContainedItems item)
        Nothing -> True

filterByEnch :: Find -> Item -> Bool
filterByEnch tree item =
    let qualList = (findItemQuals tree) in
    if null qualList then
        True
    else
        if null (extractEnchantments item) then
            any (filterByEnch tree) (extractContainedItems item)
        else
            all filterByEnchInner (extractEnchantments item) ||
                any (filterByEnch tree) (extractContainedItems item)
            where
                filterByEnchInner ItemEnchantment {enchantmentId = itemEnchId, enchantmentLevel = itemEnchLvl} = 
                    all filterByQuals (findItemQuals tree)
                    where
                        filterByQuals ItemQualEnch {itemQualEnchId = enchId, itemQualEnchAttrs = qualEnchAttrs} = 
                            if enchId == itemEnchId &&
                               all filterByEnchAttrs qualEnchAttrs then
                                True
                            else
                                False
                            where
                                filterByEnchAttrs (ItemQualLevel rel) =
                                    if (rel itemEnchLvl) then
                                        True
                                    else
                                        False
        
find :: Level -> Find -> [Item]
find level tree =
  filter (\x -> (filterById tree x) && (filterByEnch tree x)) (findPlayers ++ findWorld)
  where
    findPlayers =
      concatMap findPlayer $ levelPlayers level
      where
        findPlayer player =
          case path [Just "", Just "Inventory"] $ 
               playerData player of
            Just (ListTag _ CompoundType _ items) -> map itemize items
            _ -> []
          where
            itemize item = Item {
              itemCoords = playerCoords,
              itemSource = ItemSourcePlayer $ playerName player,
              itemData = item}
              where
                playerCoords =
                  case path [Just "", Just "Pos"] $ 
                       playerData player of
                    Just (ListTag _ DoubleType _ [ 
                           DoubleTag Nothing x, 
                           DoubleTag Nothing y, 
                           DoubleTag Nothing z ]) -> 
                      (floor x, floor y, floor z)
                    _ -> 
                      error $  "player " ++ playerName player ++ 
                               " has no position"
    findWorld =
      let d = levelDims level in
      let ds = [("surface", dimsSurface d), 
                ("nether", dimsNether d), 
                ("end", dimsEnd d)] in
      let ws = [("free", "Entities")] in
      concatMap findDim $ (,) <$> ws <*> ds
      where
        findDim ((_, _), (dimName, Just regions)) =
          concatMap findRegion regions
          where
            findRegion region =
              concatMap findChunk $ regionContents region
              where
                findChunk chunk = 
                  findEntities "Entities" findItem ++ 
                  findEntities "TileEntities" findTileItems
                  where
                    findItem ent =
                      case path [Nothing, Just "Item"] ent of
                        Just (CompoundTag (Just "Item") _) ->
                          Just $ Item {
                            itemCoords = globalCoords ent region chunk ,
                            itemSource = ItemSourceFree dimName,
                            itemData = ent}
                        _ -> Nothing
                    findTileItems ent =
                        Just $ Item {
                            itemCoords = globalCoords ent region chunk ,
                            itemSource = ItemSourceTile dimName,
                            itemData = ent
                            }
                    findEntities name extract = 
                        case path [Just "", Just "Level", Just name] $ 
                             cdChunk chunk of
                          Just (ListTag (Just n) _ _ nbts) | name == n ->
                            mapMaybe extract nbts
                          _ -> []
        findDim _ = []
