{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}

module Juno.Messaging.ZMQ (
  runMsgServer
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan.Unagi
import Control.Monad.State.Strict
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Serialize
import System.ZMQ4.Monadic

import Juno.Messaging.Types

sendProcess :: Serialize a
            => OutChan (OutBoundMsg String a)
            -> Rolodex String (Socket z Push)
            -> ZMQ z (Rolodex String (Socket z Push))
sendProcess outboxRead r = do
  (OutBoundMsg addrs msg) <- liftIO $ readChan outboxRead
  let bs = encode msg
  newRol <- updateRolodex r addrs
  toPoll <- recipList newRol addrs
  mapM_ (\s -> send s [] bs) toPoll
  sendProcess outboxRead newRol

updateRolodex :: Rolodex String (Socket z Push) -> Recipients String -> ZMQ z (Rolodex String (Socket z Push))
updateRolodex r@(Rolodex _rol) RAll = return r
updateRolodex r@(Rolodex rol) (RSome addrs) =
  if addrs `Set.isSubsetOf` Map.keysSet rol
  then return r
  else addNewAddrs r $ Set.toList addrs
updateRolodex r@(Rolodex rol) (ROne addr) =
  if Set.member addr $ Map.keysSet rol
  then return r
  else addNewAddrs r [addr]

addNewAddrs :: Rolodex String (Socket z Push) -> [Addr String] -> ZMQ z (Rolodex String (Socket z Push))
addNewAddrs r [] = return r
addNewAddrs (Rolodex r) (x:xs) = do
  r' <- if Map.member x r
        then return $ Rolodex r
        else do
          s <- socket Push
          _ <- connect s $ _unAddr x
          return $ Rolodex $ Map.insert x (ListenOn s) r
  addNewAddrs r' xs

recipList :: Rolodex String (Socket z Push) -> Recipients String -> ZMQ z [Socket z Push]
recipList (Rolodex r) RAll = return $ _unListenOn <$> Map.elems r
recipList (Rolodex r) (RSome addrs) = return $ _unListenOn <$> (r Map.!) <$> Set.toList addrs
recipList (Rolodex r) (ROne addr) = return $ _unListenOn <$> [r Map.! addr]

runMsgServer :: Serialize m
             => InChan m
             -> OutChan (OutBoundMsg String m)
             -> Addr String
             -> [Addr String]
             -> IO ()
runMsgServer inboxWrite outboxRead me addrList = void $ do
    void $ forkIO $ runZMQ $ do
      sock <- socket Pull
      _ <- bind sock $ _unAddr me
      forever $ do
        newMsg <- receive sock
        case decode newMsg of
          Left err -> liftIO $ putStrLn $ "Failure to decode: " ++ err
          Right v -> liftIO $ writeChan inboxWrite v
        liftIO $ threadDelay 1000
    threadDelay 100000 -- to be sure that the recieve side is up first
    forkIO $ runZMQ $ do
      rolodex <- addNewAddrs (Rolodex Map.empty) addrList
      void $ sendProcess outboxRead rolodex
