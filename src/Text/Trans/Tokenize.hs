{-# LANGUAGE CPP, BangPatterns #-}
-- |This module provides functionality for tokenizing text streams to
-- differentiate between printed characters and structural elements
-- such as newlines.  Once tokenized, such text streams can be
-- manipulated with the functions in this module.
module Text.Trans.Tokenize
    ( TextStream(..)
    , TextStreamEntity(..)
    , Token(..)

    -- * To and from strings
    , tokenize
    , serialize

    -- * Inspection
    , tokenLen
    , entityToken
    , streamEntities

    -- * Manipulation
    , truncateLine
    , wrapStream
    , findLines
#ifdef TESTING
    , isWhitespace
    , partitions
#endif
    )
where

import Data.List
    ( inits
    )

-- |The type of text tokens.  These should consist of printable
-- characters and NOT presentation characters (e.g., newlines).  Each
-- type of token should have as its contents a string of characters
-- all of the same type.  Tokens are generalized over an attribute
-- type which can be used to annotate each token.
data Token a = S { tokenStr :: !String
                 -- ^The token's string.
                 , tokenAttr :: !a
                 -- ^The token's attribute.
                 }
             -- ^Non-whitespace tokens.
             | WS { tokenStr :: !String
                  -- ^The token's string.
                  , tokenAttr :: !a
                  -- ^The token's attribute.
                  }
               -- ^Whitespace tokens.

-- |A text stream entity is either a token or a structural element.
data TextStreamEntity a = T !(Token a)
                        -- ^Constructor for ordinary tokens.
                        | NL
                          -- ^Newline.

-- |A text stream is a list of text stream entities.  A text stream
-- |combines structural elements of the text (e.g., newlines) with the
-- |text itself (words, whitespace, etc.).
data TextStream a = TS ![TextStreamEntity a]

instance (Show a) => Show (TextStream a) where
    show (TS ts) = "TS " ++ show ts

instance (Show a) => Show (TextStreamEntity a) where
    show (T t) = "T " ++ show t
    show NL = "NL"

instance (Show a) => Show (Token a) where
    show (S s a) = "S " ++ show s ++ " " ++ show a
    show (WS s a) = "WS " ++ show s ++ " " ++ show a

instance (Eq a) => Eq (Token a) where
    a == b = (tokenStr a) == (tokenStr b) &&
             (tokenAttr a) == (tokenAttr b)

instance (Eq a) => Eq (TextStreamEntity a) where
    NL == NL = True
    T a == T b = a == b
    _ == _ = False

instance (Eq a) => Eq (TextStream a) where
    (TS as) == (TS bs) = as == bs

-- |Get the entities in a stream.
streamEntities :: TextStream a -> [TextStreamEntity a]
streamEntities (TS es) = es

-- |Get the length of a token's string.
tokenLen :: Token a -> Int
tokenLen (S s _) = length s
tokenLen (WS s _) = length s

wsChars :: [Char]
wsChars = [' ', '\t']

isWs :: Char -> Bool
isWs = (`elem` wsChars)

isNL :: TextStreamEntity a -> Bool
isNL NL = True
isNL _ = False

-- |Gets a 'Token' from an entity or raises an exception if the entity
-- does not contain a token.  Used primarily for convenience
-- transformations in which the parameter is known to be a token
-- entity.
entityToken :: TextStreamEntity a -> Token a
entityToken (T t) = t
entityToken _ = error "Cannot get token from non-token entity"

isWhitespace :: Token a -> Bool
isWhitespace (WS _ _) = True
isWhitespace _ = False

isWsEnt :: TextStreamEntity a -> Bool
isWsEnt (T (WS _ _)) = True
isWsEnt _ = False

-- |Given a text stream, serialize the stream to its original textual
-- representation.  This discards token attribute metadata.
serialize :: TextStream a -> String
serialize (TS es) = concat $ map serializeEntity es
    where
      serializeEntity NL = "\n"
      serializeEntity (T (WS s _)) = s
      serializeEntity (T (S s _)) = s

-- |Tokenize a string and apply a default attribute to every token in
-- the resulting text stream.
tokenize :: String -> a -> TextStream a
tokenize s def = TS $ findEntities s
    where
      findEntities [] = []
      findEntities str@(c:_) = nextEntity : findEntities (drop nextLen str)
          where
            (nextEntity, nextLen) = if isWs c
                                    then (T (WS nextWs def), length nextWs)
                                    else if c == '\n'
                                         then (NL, 1)
                                         else (T (S nextStr def), length nextStr)
            nextWs = takeWhile isWs str
            nextStr = takeWhile (\ch -> not $ ch `elem` ('\n':wsChars)) str

-- |Given a list of tokens, truncate the list so that its underlying
-- string representation does not exceed the specified column width.
truncateLine :: Int -> [Token a] -> [Token a]
truncateLine l _ | l < 0 = error $ "truncateLine cannot truncate at length = " ++ show l
truncateLine _ [] = []
truncateLine width ts =
    -- If we are returning all tokens, we didn't have to do any
    -- truncation.  But if we *did* have to truncate, return exactly
    -- 'width' characters' worth of tokens by constructing a new final
    -- token with the same attribute data.
    --
    -- If there are no passing cases (i.e., remaining is null), just
    -- return 'width' characters of the first token.
    if null remaining
    then [first_tok { tokenStr = take width $ tokenStr first_tok }]
    else if length tokens == length ts
         then tokens
         else if null $ tokenStr lastToken
              then tokens
              else tokens ++ [lastToken]
    where
      lengths = map (length . tokenStr) ts
      cases = reverse $ inits lengths
      remaining = dropWhile ((> width) . sum) cases
      tokens = take (length $ head remaining) ts
      truncLength = sum $ head remaining

      first_tok = ts !! 0
      last_tok = ts !! (length tokens)
      lastToken = last_tok { tokenStr = take (width - truncLength) $ tokenStr last_tok }

-- |Given a text stream and a wrapping width, return a new
-- 'TextStream' with newlines inserted in appropriate places to wrap
-- the text at the specified column.  This function results in text
-- wrapped without leading or trailing whitespace on wrapped lines,
-- although it preserves leading whitespace in the text which was not
-- the cause of the wrapping transformation.
wrapStream :: (Eq a) => Int -> TextStream a -> TextStream a
wrapStream width (TS stream) = TS $ reverse $ dropWhile (== NL) $ reverse $ wrapAll' 0 stream
    where
      wrapAll' :: Int -> [TextStreamEntity a] -> [TextStreamEntity a]
      wrapAll' _ [] = []
      wrapAll' _ (NL:rest) = NL : wrapAll' 0 rest
      wrapAll' accum (T t:rest) =
          if (length $ tokenStr t) + accum > width
          then if isWhitespace t
               then [NL] ++ wrapAll' 0 (dropWhile isWsEnt rest)
               else if accum == 0 && ((length $ tokenStr t) >= width)
                    then [T t, NL] ++ wrapAll' 0 (dropWhile isWsEnt rest)
                    else [NL, T t] ++ wrapAll' (length $ tokenStr t) rest
          else T t : wrapAll' (accum + (length $ tokenStr t)) rest

partitions :: (a -> Bool) -> [a] -> [[a]]
partitions _ [] = []
partitions f as = p : partitions f (drop (length p + 1) as)
    where
      p = takeWhile f as

-- |Given a list of text stream entities, split up the list wherever
-- newlines occur.  Returns a list of lines of entities, such that all
-- entities wrap tokens and none are newlines.  (Safe for use with
-- 'entityToken'.)
findLines :: [TextStreamEntity a] -> [[TextStreamEntity a]]
findLines = partitions (not . isNL)
