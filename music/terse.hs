a1 = museq 1 [ (0,   Send Boop "1" ("freq",400) )
             , (0,   Send Boop "1" ("amp",0.4)  )
             , (0.5, Send Boop "1" ("amp",0)    ) ]
m1 = museq 2 [ (0,   ("amp",0)    )
             , (0.5, ("freq",500) )
             , (0.5, ("amp",0.4)  ) ]
a2 = Send Boop "2" <$> m1
a3 = fast 2 $ early (1/4) $ museq 1 [ (0,   Send Boop "3" ("freq",600) )
                                    , (0,   Send Boop "3" ("amp",0.4)  )
                                    , (0.5, Send Boop "3" ("amp",0)    ) ]

dist <- newDispatch
replaceAll dist $ M.fromList [ ("1",a1), ("2",a3)]
replaceAll dist $ M.fromList [ ("1",a1), ("2",a2)]

-- replace dist "2" a3

tid <- startDispatchLoop dist
putStrLn "dist <- newDispatch\ntid <- startDispatchLoop dist"
