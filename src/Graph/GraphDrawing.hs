{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Eta reduce" #-}
{-# HLINT ignore "Use =<<" #-}

module Graph.GraphDrawing where

import qualified Data.IntMap as I
import qualified Data.IntMap.Strict as IM
import Data.List (elemIndex, find, group, groupBy, intercalate, sort, sortBy, sortOn, (\\))
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Tuple (swap)
import qualified Data.Vector.Algorithms.Intro as I
import Data.Vector.Unboxed (Vector)
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word32)
import Debug.Trace (trace)
import Graph.CommonGraph
  ( CGraph,
    CGraphL,
    Channel,
    Column,
    EdgeClass (channelNrIn, channelNrOut, dummyEdge, standard),
    EdgeType (NormalEdge),
    GraphMoveX,
    LayerFeatures (LayerFeatures),
    NodeClass (connectionNode, dummyNode, isConnNode, isDummy, isMainArg, isSubLabel, subLabels),
    UINode,
    childrenNoVertical,
    childrenSeparating,
    childrenVertical,
    isFunction,
    myFromJust,
    myhead,
    parentsNoVertical,
    parentsVertical,
    rmdups,
    verticallyConnectedNodes,
    vhead,
  )
import qualified Graph.CommonGraph as Common
import Graph.IntMap (Graph (..), nodes)
import qualified Graph.IntMap as Graph

-- Also returns a map with Columns to allow navigation with arrows
layeredGraphAndCols ::
  (NodeClass n, Show n, EdgeClass e, Show e) =>
  Bool ->
  CGraph n e ->
  (CGraphL n e, (Map.Map GraphMoveX [UINode], Map.Map Int [Column]))
layeredGraphAndCols cross graph = (g, getColumns g)
  where
    g = layeredGraph cross graph

-- Debug with https://dreampuf.github.io/GraphvizOnline using neato or fdp engine

-- ^ Layout a directed acyclic graph in several steps (Sugiyama)
-- 1. Assign the nodes to several layers (longest path)
-- 2. Dummy vertices for lines that are longer than a layer
-- 3. Reduce crossings, place the longest path on top
-- 4. Assign y-coordinates to the nodes so that long lines that pass several layers are
--    as straight as possible

layeredGraph ::
  (VU.Unbox UINode, NodeClass n, Show n, EdgeClass e, Show e) =>
  Bool ->
  CGraph n e ->
  CGraphL n e
layeredGraph cross graph =
  -- Debug.Trace.trace ("layered "++ show graph ++"\n") -- ++ showEdges graph ++ show (Graph.edgeLabels graph)) $ -- ++"\nnewGraph\n" ++ show newGraph ++"\n") $
  newGraph
  where
    sortLayers (gr, ls) = (gr, map sort ls) -- makes the dummy vertices appear lower
    newGraph =
      ( -- subgraphWindows .
        yCoordinateAssignement
          -- .
          -- primitiveYCoordinateAssignement
          . crossingReduction 1 cross
          . sortLayers
          . addConnectionVertices
          . longestPathAlgo
          . addMissingInputNodes -- does not change the graph, only computes layers
      )
        graph

fr :: (Int, n) -> (UINode, n)
fr (n, nl) = (fromIntegral n, nl)

graphvizNodes :: (CGraph n e, Map.Map Int [Column]) -> String
graphvizNodes (gr, m) = concatMap ((++ "\n") . sh) (I.toList (Graph.nodeLabels gr))
  where
    sh (n, _nl) = show n ++ " [ pos = \"" ++ show (myFromJust 499 $ Map.lookup n m) ++ "!\"]"

primitiveYCoordinateAssignement :: (CGraph n e, [[UINode]]) -> CGraphL n e
primitiveYCoordinateAssignement (graph, layers) =
  --    Debug.Trace.trace ("primitiveY1 "++ show (graph,layers,ns)) $
  (graph, Map.fromList ns)
  where
    ns :: [(UINode, (Int, Int))]
    ns = concat $ zipWith (\layer i -> map (incX i) layer) (map oneLayer layers) ([0 ..] :: [Int])
    oneLayer l = zip (iterate incY (0, 0)) l
    incX i ((x, y), n) = (n, (x - i, y))
    incY (x, y) = (x, y + 1)
{-
primitiveYCoordinateAssignement2 :: (CGraph, [[UINode]]) -> CGraph
primitiveYCoordinateAssignement2 (g, (la:layers)) =
    Debug.Trace.trace ("primitiveY2 "++ show (g, newGraph, ns, la, layers)) $
--                       ++ show (reverse $ oneLayer newLa layers)) $
    newGraph
  where
    newGraph = g { nodeLabels = I.fromList $ map fr2 $ map (positionNode g) (concat ns) }
    ns = zipWith (\layer i -> map (incX i) layer) (oneLayer newLa layers) ([0..] :: [Int])
    newLa = zip (iterate incY (0,0)) la
    oneLayer :: [((Int,Int), UINode)] -> [[UINode]] -> [[((Int,Int), UINode)]]
    oneLayer l0 [] = [l0]
    oneLayer l0 (l1:rest) = l0 : (oneLayer newL1 rest)
      where
        newL1 = childYOrInc 0 (-1) l1

        childYOrInc _ _ [] = []
        childYOrInc y lastY (e:es)
          | isJust cy && (fromJust cy) /= lastY =
--          Debug.Trace.trace ("cy " ++ show (fromJust cy) ++" "++ show e ++ " " ++ show lu) $
                        ((0,fromJust cy),e) : childYOrInc ((fromJust cy)+1) (fromJust cy) es
          | otherwise =
--         Debug.Trace.trace ("other y "++ show y ++" cy "++ show cy ++" "++ show e) $
                        ((0,y),e) : childYOrInc (y+1) (fromMaybe y cy) es
          where cy | VU.null (child e) = Nothing
                   | otherwise = fmap snd lu
                lu = lookup (vhead 500 (child e)) (map (\(a,b) -> (b,a)) l0)
    child el = childrenNoVertical g el
    incX i ((x,y),n) = (x-i,y,n)
    incY (x,y)     = (x,y+1)
-}
{-
positionNode :: CGraph -> (Int, Int, UINode) -> (UINode, UINodeLabel)
positionNode graph (x,y,n) =
  (n, UINodeLabel { option = maybe NoOption option lu,
                    formerNonOption = maybe False formerNonOption lu,
                    uinode = maybe (DN (DummyNode 1)) uinode lu,
                    nestingFeatures = maybe Nothing nestingFeatures lu,
                    verticalNumber = maybe Nothing verticalNumber lu
                  })
    where lu = Graph.lookupNode n graph
-}

-- ^ See "Fast and Simple Horizontal Coordinate Assignment" (Brandes, Köpf)

yCoordinateAssignement :: (NodeClass n, EdgeClass e) => (CGraph n e, [[UINode]]) -> CGraphL n e
yCoordinateAssignement (graph, layers) =
  -- Debug.Trace.trace ("\nyCoordAssign "++ show (layers,graph,pos)) $
  (graph, pos)
  where
    -- newGraph = graph { nodeLabels = I.fromList placedNodes } -- for debugging (Map.fromList edgesToKeep)
    pos :: Map UINode (Int, Int)
    pos = horizontalBalancing lu ld ru rd
    lu = biasedAlignment graph yPos medians (reverse nLayers) (True, True)
    ld = biasedAlignment graph yPos medians (reverse nLayers) (True, False)
    ru = biasedAlignment graph yPos medians (reverse nLayers) (False, True)
    rd = biasedAlignment graph yPos medians (reverse nLayers) (False, False)

    -- for debugging
    --      edgesToKeep :: [(Graph.DirEdge UINode, [UIEdge])]
    --      edgesToKeep = map (\(x,y) -> (Graph.DirEdge x y, fromJust (Graph.lookupEdge (Graph.DirEdge x y) graph))) $
    --                      concat $ map (sweep medians Map.empty 0 (True,True)) (tuples (reverse nLayers))

    yPos = Map.fromList (concat enumLayers)
    enumLayers = map (\l -> zip l [0 ..]) layers
    nLayers = map (map connProp) layers
    connProp n = (n, isConnNode graph n)

    medians = (Map.fromList lowerMedians, Map.fromList upperMedians)
    upperMedians =
      -- Debug.Trace.trace ("upper"++ show (map upper ns, map (getMedian . upper) ns)) $
      mapMaybe (getMedian . upper) ns
    lowerMedians =
      -- Debug.Trace.trace ("lower"++ show (map lower ns)) $
      mapMaybe (getMedian . lower) ns
    ns = map fr $ I.toList (Graph.nodeLabels graph)
    upper (n, _) = (n, VU.toList (childrenNoVertical graph n))
    lower (n, _) = (n, VU.toList (parentsNoVertical graph n))

    getMedian (n, ns1)
      | l == 0 -- Debug.Trace.trace "get l0" $
        =
        Nothing
      | l == 1 = Just (n, Single rightMedian)
      | even l -- Debug.Trace.trace ("get lmod2"++ show (nodeLbls,ns1,(n, (leftMedian, rightMedian)))) $
        =
        Just (n, UpLowMedian leftMedian rightMedian) -- an even list has two medians
      | otherwise -- Debug.Trace.trace ("get other"++ show (nodeLbls,ns1,(n, (rightMedian, rightMedian)))) $
        =
        Just (n, Middle rightMedian) -- an odd list has only one median
      where
        leftMedian =
          -- Debug.Trace.trace ("median "++ show (n,ns1,nodeLbls,sorted,l)) $
          addConnProp (sorted !! ((l `div` 2) - 1))
        rightMedian = addConnProp (sorted !! (l `div` 2))
        l = length ns1
        sorted = sortBy py nodeLbls
        py (y0, _) (y1, _) = compare y0 y1
        nodeLbls = map (\node -> (fromMaybe 0 (Map.lookup node yPos), node)) ns1
        addConnProp (y, node) = (y, (node, isConnNode graph node))

-- the paper suggest to use an average of four alignments (TODO)
horizontalBalancing :: Map UINode (X, Y) -> Map UINode (X, Y) -> Map UINode (X, Y) -> Map UINode (X, Y) -> Map UINode (X, Y)
horizontalBalancing lu _ld _ru _rd =
  -- Debug.Trace.trace ("horizontalBalancing "++ show (lu,ru)) --  ++"\n"++ show ld ++"\n"++ show average)
  -- lu -- ld ru rd
  lu

-- average = zipWith f lu ru
--        f :: (UINode,(X,Y)) -> (UINode,(X,Y)) -> (UINode,(X,Y))
--        f (n0,(x0,y0)) (n1,(x1,y1)) | n0 /= n1 = error "horizontalBalancing n0 /= n1 "
--                                    | otherwise = (n0, (x0, (y0+y1) `div` 2 ))

type X = Int

type Y = Int

type YN = (Y, (UINode, Bool))

data MYN
  = Single (Y, (UINode, Bool)) -- no medians because there is only one connection
  | Middle (Y, (UINode, Bool)) -- an odd number of connections has only one median
  | UpLowMedian (Y, (UINode, Bool)) (Y, (UINode, Bool))
  deriving (Eq, Ord, Show) -- an even number of connections has two medians

type Median = Map UINode MYN

biasedAlignment ::
  (NodeClass n, EdgeClass e) =>
  CGraph n e ->
  Map UINode Y ->
  (Median, Median) ->
  [[(UINode, Bool)]] ->
  (Bool, Bool) ->
  Map UINode (X, Y)
biasedAlignment graph _ medians layers dir =
  -- Debug.Trace.trace ("\nbalign"++ show (layers, balign)) $ --edgesToKeep, map sweep2 (tuples layers)) ++
  --                                                                "\nunpositioned " ++ show (map removePositioned (map (map fst) layers))) $
  balign
  where
    (left, _up) = dir
    positioned = Map.keys balign
    _removePositioned ns = ns \\ positioned
    -- see with https://dreampuf.github.io/GraphvizOnline/
    balign =
      -- Debug.Trace.trace ("\n\nedgesToKeep "++ show dir ++ "\ndigraph G {" ++
      --                   (concat $ map line edgesToKeep) ++"\n"++ placeNodes ++ "\n}") -- \n\nmedians "++ show medians) $
      align graph (map (map fst) layers) edgesToKeep dir
    edgesToKeep = rmdups $ concatMap (concatMap resolve . sweep2) (tuples layers)
    _line (from, to) = "\n" ++ show from ++ " -> " ++ show to
    _placeNodes = concat $ concatMap (map placeNode) (zipWith (zip . repeat) [1 ..] (map (zip [1 ..]) layers))
      where
        placeNode :: (X, (Y, (UINode, Bool))) -> String
        placeNode (x, (y, (n, _b))) = show n ++ " [pos=\"" ++ show x ++ "," ++ show (-y) ++ "!\"];\n"
    resolve :: [(MYN, MYN)] -> [(UINode, UINode)]
    resolve ts =
      -- Debug.Trace.trace ("\nresolve "++ show (ts, res))
      res
      where
        res = rmdups $ map toNode (resolveConflicts dir ts)

    _sweep :: ([(UINode, Bool)], [(UINode, Bool)]) -> [[(MYN, MYN)]]
    _sweep (layer0, layer1) =
      -- Debug.Trace.trace ("\nsweep "++ show (dir, layer0, layer1) ++"\n"++ show sfiel)
      -- Debug.Trace.trace ("(l0,l1)\n"++ show (layer0, layer1) ++"\n\n"++ show medians ++"\n\n"++ show sfiel) $
      sfiel
      where
        sfiel = sweepForIndependentEdgeLists graph medians allowedEdges dir (Map.empty, Map.empty) (0, 0) (layer0, layer1) Set.empty
        allowedEdges :: Set.Set (UINode, UINode)
        allowedEdges = Set.fromList (mapMaybe f layer0)
        --              f :: UINode -> (UINode, UINode)
        f (n, _b)
          | isJust lu = Just (n, dest)
          | otherwise = Nothing
          where
            dest = fst $ snd $ getYN (fst dir) (myFromJust 500 lu)
            lu = Map.lookup n (snd medians)

    -- sweeping through a layer to find all edges without separating them into independent lists
    -- maybe slower in some cases, faster in others
    sweep2 :: ([(UINode, Bool)], [(UINode, Bool)]) -> [[(MYN, MYN)]]
    sweep2 (layer0, _layer1) =
      -- Debug.Trace.trace ("sweep2 "++ show (layer0, layer1,es))
      es
      where
        es = [catMaybes (zipWith f [0 ..] layer0)]
        f y (n, b)
          | isJust lu && isValidEdge -- Debug.Trace.trace ("sweep2lu0 "++ show lu) $
            =
            Just (Single (y, (n, b)), myFromJust 501 lu)
          | otherwise -- Debug.Trace.trace ("sweep2lu1 "++ show (n,lu))
            =
            Nothing
          where
            lu = Map.lookup n (snd medians)
            luBack = Map.lookup (fst $ snd $ getYN left $ myFromJust 502 lu) (fst medians)
            isValidEdge =
              -- Debug.Trace.trace ("n,lu,luBack "++ show (n,lu,luBack)) $
              isJust luBack && n == fst (snd $ getYN left $ myFromJust 503 luBack)

toNode :: ((a1, (a2, b1)), (a3, (b2, b3))) -> (a2, b2)
toNode ((_, (n0, _)), (_, (n1, _))) = (n0, n1)

tuples :: [a] -> [(a, a)]
tuples (x : y : xs) = (x, y) : tuples (y : xs)
tuples _ = []

type Insp = (Map Int (MYN, MYN), Map Int (MYN, MYN))

-- | Takes two layers and returns a list of lists of independent edges.
--   A list A of edges is independent of a list B of edges if every edge of A does not intersect or connect any edge of B.
--   This sweeping should save some time because graphs often have edges crossing near to each other.
--   The number of intersections has been reduced in crossingreduction.
--   Because of this we can assume that most edges are quite short and rectangular to layer0 and layer1.
--   A sweep in the parallel direction of the two layers should reduce the number of edges that have to be examined.
--   The overall algorithm (sweep + resolve) should have a runtime more like n*log(n) instead of n²,
--   because we only have to search for conflicts inside of these independent lists.
--   The Brandes-Köpf paper is not explaining very well how they find intersections between two layers.
--   I doubt that the whole algorithm is O(n). It seems more like a quadratic runtime in the worst case.
--   Even finding the number of intersections (without giving back the exact edges that intersect) is O(n log n),
--   See:  Simple and Efficient Bilayer Cross Counting by Barth, Mutzel, Jünger
--        or chapter 33 of Cormen: Introduction to algorithms
--   If several edges emanate from a node the algorithm takes (one of the) the median. (e.g. three edges have one median, 4 edges have two)
--   The sweep works by looking at the next node in the two layers, and comparing which node deletes more edges and
--   introduces less new edges from the set of edges to look at. Every edge has a start node (first appearing at its
--   y-position) and an end node. A start node means adding an edge when its source or target node appears in one of
--   the two layers, and the edge disappears when both its nodes have been swept over.
sweepForIndependentEdgeLists ::
  (NodeClass n, EdgeClass e) =>
  CGraph n e ->
  (Median, Median) ->
  Set (UINode, UINode) ->
  (Bool, Bool) ->
  Insp ->
  (Y, Y) ->
  ([(UINode, Bool)], [(UINode, Bool)]) ->
  Set (MYN, MYN) ->
  [[(MYN, MYN)]]
sweepForIndependentEdgeLists graph medians allowedEdges dir inspectionEdges (y0, y1) (layer0, layer1) missingEdges
  | null layer0 && null layer1 = Debug.Trace.trace ("nullnull " ++ show (layer0, layer1)) []
  | y0 >= 10 || y1 >= 10 = Debug.Trace.trace ("1010 " ++ show (y0, y1, layer0, layer1)) []
  | -- node at postion y1 is connected vertically with node at position y1+1
    (length layer1 >= 2) && verticalNode && isFunction graph hl1 =
    -- Debug.Trace.trace "sweep vert node" $
    sweepForIndependentEdgeLists graph medians allowedEdges dir sweepedOver (y0, y1 + 1) (layer0, tl1) Set.empty
  | Map.null sweepedOverFrom && Map.null sweepedOverTo =
    -- Debug.Trace.trace ("res"++ show (y0,y1) ++"\nlayer0 "++ show layer0 ++"\nlayer1 "++ show layer1
    --                    ++"\nresEdges "++ show resEdges ++"\nnewInsFrom "++ show newInsFrom ++"\nnewInsTo "
    --                    ++ show newInsTo ++"\nsweepedOver "++ show sweepedOver ++"\n") $
    resEdges : (sweepForIndependentEdgeLists graph medians allowedEdges dir sweepedOver (y0 + 1, y1 + 1) (tl0, tl1) Set.empty)
  | Map.size sweepedOverFrom < Map.size sweepedOverTo =
    -- Debug.Trace.trace (show (Map.size sweepedOverFrom)++ "<"++ show (Map.size sweepedOverTo) ++"\n"++
    --       show (y0,y1) ++"\nnewInsFrom "++ show newInsFrom ++"\nnewInsTo "++ show newInsTo
    --     ++"\nsweepedOverFrom "++ show sweepedOverFrom ++"\nsweepedOverTo "++ show sweepedOverTo ++"\n") $
    sweepForIndependentEdgeLists
      graph
      medians
      allowedEdges
      dir
      sweepedOver
      (y0 + 1, y1)
      (tl0, layer1)
      (Set.union missingEdges newMissingEdges)
  | otherwise -- Debug.Trace.trace (show (Map.size sweepedOverFrom)++ ">="++ show (Map.size sweepedOverTo) ++"\n"++
  --       show (y0,y1) ++"\nnewInsFrom "++ show newInsFrom ++"\nnewInsTo "++ show newInsTo
  --       ++"\nsweepedOverFrom "++ show sweepedOverFrom ++"\nsweepedOverTo "++ show sweepedOverTo ++"\n") $
    =
    sweepForIndependentEdgeLists
      graph
      medians
      allowedEdges
      dir
      sweepedOver
      (y0, y1 + 1)
      (layer0, tl1)
      (Set.union missingEdges newMissingEdges)
  where
    (inspectEdgesFrom, inspectEdgesTo) = inspectionEdges
    (lowerMedians, upperMedians) = medians
    (left, _up) = dir
    (n0, b0) = myhead 60 layer0
    (n1, b1) = myhead 61 layer1
    tl0
      | null layer0 = []
      | otherwise = tail layer0
    tl1
      | null layer1 = []
      | otherwise = tail layer1
    hl1 = fst (myhead 62 layer1)
    verticalNode = VU.elem (fst (myhead 63 tl1)) (Graph.adjacentNodesByAttr graph True hl1 (Graph.Edge8 Common.vertBit))
    resEdges = myNub (Map.elems newInsFrom ++ Map.elems newInsTo ++ Set.toList missingEdges)

    edgeFrom :: Maybe MYN
    edgeFrom
      | null layer0 = Nothing
      | otherwise -- Debug.Trace.trace ("up2 "++ show (n0, Map.lookup n0 upperMedians)) $
        =
        Map.lookup n0 upperMedians
    edgeTo :: Maybe MYN
    edgeTo
      | null layer1 --  || (not (Set.member (n0,n1) allowedEdges))
        =
        Nothing
      | otherwise -- Debug.Trace.trace ("up4 "++ show (n1, Map.lookup n1 lowerMedians)) $
        =
        Map.lookup n1 lowerMedians

    newInsFrom :: Map Int (MYN, MYN)
    newInsFrom
      | isJust edgeFrom && yy1 >= y1 = Map.insert yy1 (Single (y0, (n0, b0)), myFromJust 504 edgeFrom) inspectEdgesFrom
      | otherwise = inspectEdgesFrom
      where
        yy1 = getY left (myFromJust 505 edgeFrom)

    newInsTo :: Map Int (MYN, MYN)
    newInsTo
      | isJust edgeTo && yy0 >= y0 = Map.insert yy0 (myFromJust 506 edgeTo, Single (y1, (n1, b1))) inspectEdgesTo
      | otherwise = inspectEdgesTo
      where
        yy0 = getY left (myFromJust 506 edgeTo)

    newMissingEdges :: Set.Set (MYN, MYN)
    newMissingEdges
      | isJust edgeFrom && isJust edgeTo =
        Set.fromList
          [ (Single (y0, (n0, b0)), myFromJust 507 edgeFrom),
            (myFromJust 508 edgeTo, Single (y1, (n1, b1)))
          ]
      | isJust edgeFrom = Set.singleton (Single (y0, (n0, b0)), myFromJust 509 edgeFrom)
      | isJust edgeTo = Set.singleton (myFromJust 510 edgeTo, Single (y1, (n1, b1)))
      | otherwise = Set.empty

    sweepedOverFrom = Map.delete y1 newInsFrom
    sweepedOverTo = Map.delete y0 newInsTo
    sweepedOver = (sweepedOverFrom, sweepedOverTo) :: Insp

-- | Either e0 prevails against all e1s or all e1s prevail against e0
data EdgeTy a = E0Prevails a | E1Prevails a | NoIntersect (a, a) deriving (Eq, Show)

resolveConflicts :: (Bool, Bool) -> [(MYN, MYN)] -> [(YN, YN)]
resolveConflicts (_, _) [] = []
resolveConflicts (left, _) [e] = [toYN left e]
resolveConflicts (left, up) es =
  -- Debug.Trace.trace ("resolveConflicts"++ show (es, resolveConfs (left,up) es 0)) $
  map (toYN left) (resolveConfs (left, up) es 0)

toYN :: Bool -> (MYN, MYN) -> ((Y, (UINode, Bool)), (Y, (UINode, Bool)))
toYN left (n0, n1) = (getYN left n0, getYN left n1)

-- | Compare all edges of a layer with each other. Worst case: O(n²).
-- But n can shrink fast in every round and n is small, because of sweepForIndependentEdgeLists
resolveConfs :: (Bool, Bool) -> [(MYN, MYN)] -> Int -> [(MYN, MYN)]
resolveConfs (_, _) [] _ =
  -- Debug.Trace.trace "ch0 "
  []
resolveConfs (left, up) (e0 : edges) i
  | i > 20 -- Debug.Trace.trace ("ch1 "++ show (e0:edges))
    =
    e0 : edges -- avoid endless loop
  | checkE0 consistent -- Debug.Trace.trace ("checkE0 "++ show (map te (e0:edges)) ++"\n"++ show (map _toEdges2 conflictList) ++"\n") $
    =
    e0 : (resolveConfs (left, up) removeInferiorToE0 (i + 1))
  | checkNoIntersect consistent -- Debug.Trace.trace ("check noIntersect "++ show (map te (e0:edges)) ++"\n"++ show (conflictList, consistent, i) ++ "\n") $
    =
    if null conflictList
      then e0 : edges
      else e0 : (resolveConfs (left, up) edges (i + 1)) -- concat (map toEdges conflictList)
  | otherwise -- Debug.Trace.trace ("checkE1 "++ show (map te (e0:edges)) ++"\n"++ show (conflictList, consistent, i, firstE1, edgesE1First) ++ "\n") $
    =
    resolveConfs (left, up) edgesE1First (i + 1)
  where
    conflictList = map (conflict left e0) edges

    edgesE1First = e1 : (filter (\e -> e /= e0 && e /= e1) (concatMap toEdges conflictList))
    e1 = head (toEdges firstE1)
    firstE1 = myFromJust 511 (find e1Prevails conflictList)

    consistent = isConsistent conflictList
    checkE0 (E0Prevails True) = True
    checkE0 _ = False
    _checkE1 (E1Prevails True) = True
    _checkE1 _ = False
    checkNoIntersect (NoIntersect _) = True
    checkNoIntersect _ = False
    removeInferiorToE0 = rmdups $ concatMap toEdges (filter isNoIntersect conflictList)
    isNoIntersect (NoIntersect _) = True
    isNoIntersect _ = False
    e1Prevails (E1Prevails _) = True
    e1Prevails _ = False
    toEdges (E0Prevails e) = [e]
    toEdges (E1Prevails e) = [e]
    toEdges (NoIntersect (edge0, edge1)) = [edge0, edge1]

    _toEdges2 (E0Prevails (n0, n1)) = [te1 (n0, n1)]
    _toEdges2 (E1Prevails (n0, n1)) = [te1 (n0, n1)]
    _toEdges2 (NoIntersect ((n0, n1), (n2, n3))) = [te1 (n0, n1), te1 (n2, n3)]
    te1 (n0, n1) = (getN n0, getN n1)

-- resolveConfs _ _ _ = Debug.Trace.trace "error resolveConfs " []

-- | The resolveConflicts-algorithm has to be constructed in a consistent way
--   It should be impossible that edge e has priority to edge x (keeping e),
--   and another edge y has priority to edge e (deleting e). It would not be clear if e has to be deleted or not
isConsistent :: [EdgeTy (MYN, MYN)] -> EdgeTy Bool
isConsistent (NoIntersect _ : es) = isConsistent es
isConsistent [] = NoIntersect (True, True) -- will only be called if there is no E0Prevails or E1Prevails
isConsistent ((E0Prevails _) : es) = isAllE0OrNoIntersect es
  where
    isAllE0OrNoIntersect [] = E0Prevails True
    isAllE0OrNoIntersect ((E0Prevails _) : edges) = isAllE0OrNoIntersect edges
    isAllE0OrNoIntersect ((NoIntersect _) : edges) = isAllE0OrNoIntersect edges
    isAllE0OrNoIntersect (_ : _) = E0Prevails False -- not consistent
isConsistent ((E1Prevails _) : es) = isAllE1OrNoIntersect es
  where
    isAllE1OrNoIntersect [] = E1Prevails True
    isAllE1OrNoIntersect ((E1Prevails _) : edges) = isAllE1OrNoIntersect edges
    isAllE1OrNoIntersect ((NoIntersect _) : edges) = isAllE1OrNoIntersect edges
    isAllE1OrNoIntersect (_ : _) = E1Prevails False

conflict :: Bool -> (MYN, MYN) -> (MYN, MYN) -> EdgeTy (MYN, MYN)
conflict left (n0, n1) (n2, n3)
  | isIntersecting -- Debug.Trace.trace ("intersecting "++ show (n0,n1,n2,n3)) $
    =
    cases left (n0, n1) (n2, n3)
  | otherwise = NoIntersect ((n0, n1), (n2, n3))
  where
    isIntersecting -- two segments intersect
      =
      (getY left n0 <= getY left n2 && getY left n1 >= getY left n3)
        || (getY left n0 >= getY left n2 && getY left n1 <= getY left n3)

-- | Given two edges that intersect or connect, which one will prevail?
cases :: Bool -> (MYN, MYN) -> (MYN, MYN) -> EdgeTy (MYN, MYN)
cases left (n0, n1) (n2, n3)
  -- type 2 (one segment consists of two connection nodes and is preferred then)
  | connNode n0 && connNode n1 -- Debug.Trace.trace ("type2 0 "++ show (n0,n1,n2,n3)) $
    =
    E0Prevails (n0, n1)
  | connNode n2 && connNode n3 -- Debug.Trace.trace ("type2 1 "++ show (n0,n1,n2,n3)) $
    =
    E1Prevails (n2, n3)
  | (connNode n0 || connNode n1)
      && (connNode n2 || connNode n3) -- one connection node (type 2)
    =
    if (isMedian n0 || isMedian n1) && isSingle n2 && isSingle n3
      then -- Debug.Trace.trace ("type2 2 "++ show (n0,n1,n2,n3)) $
        E0Prevails (n0, n1)
      else E0Prevails (n2, n3)
  -- type 1 (non-inner segment crosses an inner segment)
  | (connNode n0 || connNode n1)
      && not (connNode n2)
      && not (connNode n3) -- Debug.Trace.trace ("type1 0"++ show (n0,n1,n2,n3)) $
    =
    E0Prevails (n0, n1)
  | (connNode n2 || connNode n3)
      && not (connNode n0)
      && not (connNode n1) -- Debug.Trace.trace ("type1 1"++ show (n0,n1,n2,n3)) $
    =
    E1Prevails (n2, n3)
  -- type 0 (a pair of non-inner segments)
  | not (connNode n0) && not (connNode n1)
      && not (connNode n2)
      && not (connNode n3) -- Debug.Trace.trace ("type0 "++ show (preferE0,n0,n1,n2,n3)) $
    =
    if preferE0
      then E0Prevails (n0, n1)
      else E1Prevails (n2, n3)
  | otherwise = Debug.Trace.trace "cases err" $ E0Prevails (n0, n1) -- correct? just to fix a warning
  where
    connNode (Single (_, (_, b))) = b
    connNode (Middle (_, (_, b))) = b
    connNode (UpLowMedian (_, (_, b0)) (_, (_, b1)))
      | left = b0
      | otherwise = b1
    isMedian (Single _) = False
    isMedian (Middle _) = True
    isMedian (UpLowMedian _n0 _n1) = True
    isSingle (Single _) = True
    isSingle _ = False
    preferE0
      | (isMedian n0 || isMedian n1) && not (isMedian n2) && not (isMedian n3) -- Debug.Trace.trace "p0"
        =
        True
      | (isMedian n2 || isMedian n3) && not (isMedian n0) && not (isMedian n1) -- Debug.Trace.trace "p1"
        =
        False
      | abs (getY left n0 - getY left n1) < abs (getY left n2 - getY left n3) -- Debug.Trace.trace "p2"
        =
        True
      | otherwise -- Debug.Trace.trace "p3"
        =
        False

getYN :: Bool -> MYN -> (Y, (UINode, Bool))
getYN _ (Single (y, (n, b))) = (y, (n, b))
getYN _ (Middle (y, (n, b))) = (y, (n, b))
getYN left (UpLowMedian (y0, (n0, b0)) (y1, (n1, b1)))
  | left = (y0, (n0, b0))
  | otherwise = (y1, (n1, b1))

getY :: Bool -> MYN -> Y
getY _ (Single (y, _)) = y
getY _ (Middle (y, _)) = y
getY left (UpLowMedian (y0, (_n0, _b0)) (y1, (_n1, _b1)))
  | left = y0
  | otherwise = y1

getN :: MYN -> [UINode]
getN (Single (_y, (n, _b))) = [n]
getN (Middle (_y, (n, _b))) = [n]
getN (UpLowMedian (_y0, (n0, _b0)) (_y1, (n1, _b1))) = [n0, n1]

ranksame :: [[UINode]] -> String
ranksame ls = "{ rank=same; " ++ intercalate "," (map show ls) ++ " }\n"

col :: Int -> UINode -> String
col i n = show n ++ " " ++ c (i `mod` 5) ++ "\n"
  where
    c m
      | m == 0 = "[color = red" ++ width
      | m == 1 = "[color = green" ++ width
      | m == 2 = "[color = blue" ++ width
      | m == 3 = "[color = yellow" ++ width
      | m == 4 = "[color = turquoise" ++ width
    c _ = "[color = black" ++ width
    width = ",penwidth=" ++ show (1 + (i `div` 2)) ++ "]"

--------------------------------------------------------------------------------------------------------------------

-- Similar to Brandes-Köpf but without arrays and no placement of blocks
-- The basic algorithm is longest path.
-- debugging can be done with graphviz, also uncomment line 533 in longestPath | otherwise
align :: EdgeClass e => CGraph n e -> [[UINode]] -> [(UINode, UINode)] -> (Bool, Bool) -> Map UINode (Int, Int)
align graph layers edges (_alignLeft, _up) =
  {-Debug.Trace.trace ("\nalign\ndigraph{\n"++ (concat $ map ranksame layers)
                      ++ (concat (map ((++ "\n") . (intercalate " -> ") . (map show)) layers))
                      ++ (graphviz "[color=red,penwidth=2];" edges)
                      ++ (graphviz "" es) ++ "}\n"
                      ++ show (startNs, map last (zipWith f [0..] layers))
                      ++"\nblocks\n"++ show blocks ++ "\nnextInLayerMap" ++ show nextInLayerMap
                    )-}
  mb2
  where
    --  | up = lp
    --  | otherwise = lpBackwards
    -- mb = Debug.Trace.trace ("lp\n" ++ show lp ++ "\nmb\n" ++ show (moveBlocks (Map.fromList lp))) $
    --     moveBlocks (Map.fromList lp)
    mb2 =
      -- Debug.Trace.trace ("lp\n" ++ show lp ++ "\nmb\n" ++ show (moveBlocks (Map.fromList lp), moveBlocksAgain (Map.fromList lp)) ++ "\n") $
      moveBlocksAgain (Map.fromList lp)
    lp = longestPath (map blockChildren startNs) [] 0
    --        globalYMin = minimum (map (snd . snd) lp)
    --        lpBackwards = longestPath (map blockChildren startNsBackwards) [] 0
    layerConnections = Map.fromList $ concatMap tuples layers
    reverseLayerConnections = Map.fromList $ concatMap (tuples . reverse) layers
    edgeMap = Map.fromList edges
    reverseBlocks = Map.fromList (map swap edges)
    _es = Map.keys (Graph.edgeLabels graph) \\ edges

    startNs = mapMaybe (nodeWithoutParent . last) (zipWith f [0 ..] layers)
    --        startNsBackwards = catMaybes $ map (nodeWithoutParent . head) (zipWith f [0..] layers)
    f i ns = map (i,) ns

    nodeWithoutParent (x, n)
      | isNothing (Map.lookup n reverseBlocks)
          && noParentInLayer (x, n) -- no parent in block
        =
        --  Debug.Trace.trace ("nodeWoPar0 "++ show (n, Map.lookup n reverseBlocks, noParentInLayer (x,n))) $
        Just (x, n)
      | otherwise =
        --  Debug.Trace.trace ("nodeWoPar1 "++ show (n, Map.lookup n reverseBlocks, noParentInLayer (x,n))) $
        Nothing
      where
        noParentInLayer root =
          -- Debug.Trace.trace ("noParInLayer "++ show (root, blockChildren root,
          --                   map hasNoLayerParent (blockChildren root))) $
          all hasNoLayerParent (blockChildren root)

        hasNoLayerParent (_, _n) = isNothing (Map.lookup n layerConnections)

    blockChildren :: (X, UINode) -> [(X, UINode)]
    blockChildren (x, n)
      | isJust lu = (x, n) : blockChildren (x + 1, myFromJust 513 lu)
      | otherwise = [(x, n)]
      where
        lu = Map.lookup n edgeMap

    longestPath :: [[(X, UINode)]] -> [UINode] -> Int -> [(UINode, (Int, Int))]
    longestPath [] _ _ =
      -- Debug.Trace.trace "finish"
      []
    longestPath blockNodes used i
      | i > 100 -- Debug.Trace.trace ("reverseBlocks " ++ show (edges, reverseBlocks)) $
        =
        []
      | otherwise -- Debug.Trace.trace ((concat $ map (col i) blns) ++ "\n") $
      --      ++ "map layerChild " ++ show (map layerChild (concat blockNodes)) ++ "\n"
      --      ++ "nextLayerRoots " ++ show nextLayerRoots ++ "\n"
      --      ++ "map blockChildren nextLayerRoots " ++ show (map blockChildren nextLayerRoots) ++ "\n"
      --      ++ "blocksWithOnlyUsedParents " ++ show blocksWithOnlyUsedParents ++ "\n"
      --      ++ "newUsed " ++ show newUsed
      --                ) $
        =
        newLayer ++ longestPath blocksWithOnlyUsedParents newUsed (i + 1)
      where
        newLayer = concatMap (oneLayer i) blockNodes
        blocksWithOnlyUsedParents = rmdups $ filter noParentOrUsed (map blockChildren nextLayerRoots)
        --                                          | otherwise = rmdups $ filter noParentOrUsed (map blockChildren nextLayerRootsBackwards)
        nextLayerRoots = myNub2 (map findRoot nextPossibleLayerNodes)
        --                nextLayerRootsBackwards = myNub2 (map findRoot nextPossibleLayerNodesBackwards)
        nextPossibleLayerNodes = mapMaybe layerChild (concat blockNodes)
        --                nextPossibleLayerNodesBackwards = catMaybes (map layerParent (concat blockNodes))
        layerChild (x, n) = maybe Nothing (\node -> Just (x, node)) (Map.lookup n reverseLayerConnections)
        --                layerParent (x,n) = maybe Nothing (\node -> Just (x,node)) (Map.lookup n layerConnections)
        newUsed = used ++ blns
        blns = map snd (concat blockNodes)
        noParentOrUsed block =
          -- Debug.Trace.trace ("noParentOrUsed "++ show (block, map noParOrUsed block, newUsed)) $
          all noParOrUsed block
        noParOrUsed (_, n) =
          -- Debug.Trace.trace ("noParOrUsed "++ show (n,lu)) $
          isNothing lu || (isJust lu && elem (myFromJust 514 lu) newUsed)
          where
            lu = Map.lookup n layerConnections

    oneLayer :: Y -> [(X, UINode)] -> [(UINode, (Int, Int))]
    oneLayer y ns = map (\(x, n) -> (n, (x, -y))) ns

    findRoot :: (X, UINode) -> (X, UINode)
    findRoot (x, n)
      | isJust lu && x >= 0 -- Debug.Trace.trace ("findRoot " ++ show (x,n)) $
        =
        findRoot (x - 1, myFromJust 515 lu)
      | otherwise = (x, n)
      where
        lu = Map.lookup n reverseBlocks

    blocks = extr ++ (map (\x -> [x]) rest)
      where
        extr = extractBlocks edgeMap
        rest = (concat layers \\ allNodes) \\ concat extr
        allNodes = Map.keys edgeMap ++ Map.elems edgeMap

    extractBlocks :: Map UINode UINode -> [[UINode]]
    extractBlocks m
      | Map.null m = []
      | otherwise = oneBlock ++ extractBlocks newEdgeMap -- extract one block and remove keys from the edge map
      where
        newEdgeMap =
          -- Debug.Trace.trace ("oneBlock " ++ show oneBlock) $
          foldr Map.delete m (concat oneBlock)
        oneBlock =
          filter
            (not . null)
            ( merge1 (map (fst . snd) oneBlockWithVerts)
                ++ [map fst oneBlockWithVerts]
                ++ merge1 (map (snd . snd) oneBlockWithVerts)
            )
        merge1 [] = []
        merge1 xs = (map head fil) : (merge1 (map tail fil))
          where
            fil = filter (not . null) xs
        oneBlockWithVerts =
          -- Debug.Trace.trace ("oneBlock " ++ show (reverse (blockNodesDown (head ks)), tail (blockNodesUp (head ks)))) $
          reverse (blockNodesDown (head ks))
            ++ tail (blockNodesUp (head ks))

        ks = Map.keys m ++ Map.elems m

        blockNodesDown :: UINode -> [(UINode, ([UINode], [UINode]))]
        blockNodesDown n
          | isJust lu = (n, (vertup, vertdown)) : (blockNodesDown (myFromJust 513 lu))
          | otherwise = [(n, (vertup, vertdown))]
          where
            lu = Map.lookup n edgeMap
            vertup = VU.toList (parentsVertical graph n)
            vertdown = VU.toList (childrenVertical graph n)

        blockNodesUp :: UINode -> [(UINode, ([UINode], [UINode]))]
        blockNodesUp n
          | isJust lu = (n, (vertup, vertdown)) : (blockNodesUp (myFromJust 513 lu))
          | otherwise = [(n, (vertup, vertdown))]
          where
            lu = Map.lookup n reverseBlocks
            vertup = VU.toList (parentsVertical graph n)
            vertdown = VU.toList (childrenVertical graph n)

    moveBlocks m =
      -- Debug.Trace.trace ("blocks" ++ show blocks ++ "\nm\n" ++ show (foldr moveToShortestConnection m (reverse blocks)))
      foldr moveToShortestConnection m (reverse blocks)
    moveBlocksAgain m =
      -- Debug.Trace.trace ("blocks" ++ show blocks ++ "\nm\n" ++ show (foldr moveToShortestConnection m (reverse blocks)))
      foldr moveToShortestConnection (moveBlocks m) (reverse blocks)

    moveToShortestConnection block m
      | null bs = m
      | otherwise = -- Debug.Trace.trace ("\nblock " ++ show block ++
      --       "\nbounds " ++ show bounds ++
      --       "\nnewY " ++ show newY ++
      --       "\nadjustY block newY m\n" ++ show (adjustY block newY m))
        adjustY block newY m
      where
        -- newY = ( (fromJust (fst (head bounds))) + (fromJust (snd (head bounds))) ) `div` 2
        bs = mapMaybe fst bounds
        newY = maximum bs + 1 -- TODO look at block connections
        bounds = map blockBound block
        blockBound b =
          -- Debug.Trace.trace ("blockBound " ++ show (b,n,(yTop,yBottom),m))
          (yTop, yBottom)
          where
            -- yTop = fmap snd (maybe (Just (0,globalYMin)) (\node -> Map.lookup node m) n)
            yTop = fmap snd (maybe Nothing (`Map.lookup` m) n)
            yBottom = fmap snd (Map.lookup b m)
            n = Map.lookup b nextInLayerMap

    nextInLayerMap = foldr addLayerEdges Map.empty layers
      where
        addLayerEdges layer m = foldr addEdge m (tuples layer)
        addEdge (from, to) m = Map.insert to from m

    adjustY block newY m = foldr adj m block
      where
        adj b mp = Map.adjust (\(x, _y) -> (x, newY)) b mp

---------------------------------------------------------------------------------------------------------

-- The idea behind the following heuristic:
-- Very frequent chaining of functions are obvious and need no attention, e.g. Data.Text.pack str
-- unusual chainings need the highest attention
-- a long path means it is the main path of activity, like a table of contents in a book that
-- is a guide where to go. This long path should be a straight line at the top of the page.

-- Sort nodes in the layers by:
--   Finding the longest path with the most infrequent connections, make these nodes appear
--   first (y=0) use dfs to find the second longest/infrequent path
-- longestinfrequentPaths :: CGraph -> [[Node]] -> [Node]

type YNode = (YPos, Channel, UINode, IsDummy)

type YPos = Word32

type IsDummy = Bool

data Dir = LeftToRight | RightToLeft deriving (Show)

leftToRight :: Dir -> Bool
leftToRight LeftToRight = True
leftToRight RightToLeft = False

longestinfrequentPaths :: EdgeClass e => NodeClass n => CGraph n e -> [[UINode]] -> Vector Int
longestinfrequentPaths _ [] = VU.empty
longestinfrequentPaths _ [_] = VU.empty
longestinfrequentPaths g (l0 : l1 : layers)
  | null r = VU.empty
  | otherwise = VU.take (length layers + 2) $ myhead 64 r
  where
    r = map (liPaths g (l1 : layers) []) (startNodes g l0 l1)

startNodes :: EdgeClass e => CGraph n e -> [Word32] -> [Word32] -> [Word32]
startNodes g l0 l1 = mapMaybe (nodeWithChildInLayer l1) l0
  where
    nodeWithChildInLayer layer1 node
      | VU.null $
          VU.filter
            (`elem` layer1)
            (childrenNoVertical g node) =
        Nothing
      | otherwise = Just node

liPaths :: EdgeClass e => NodeClass n => CGraph n e -> [[UINode]] -> [UINode] -> UINode -> Vector Int
liPaths _ [] ns node = VU.fromList (map fromIntegral (node : ns))
liPaths g (l0 : layers) ns node = VU.concatMap (liPaths g layers (node : ns)) cs
  where
    cs =
      VU.filter
        --        (\x -> (maybe False (not . isDummyLabel) (Graph.lookupNode x g)) && elem x l0)
        (\x -> not (isDummy g x) && elem x l0)
        (childrenNoVertical g node)

myNub :: Ord a => [a] -> [a]
myNub = map (myhead 65) . group . sort

myNub2 :: [(Int, UINode)] -> [(Int, UINode)]
myNub2 = map (myhead 66) . groupBy nnn . sortBy nn
  where
    nn (_, n0) (_, n1) = compare n0 n1
    nnn (_, n0) (_, n1) = n0 == n1

type UnconnectedChildren = [UINode]

-- | Every graph has a longest path, which is the center of attention for us
-- Return layers of node ids
-- This algorithm is a little bit more complicated because we can connect nodes "vertically",
-- so that they are guaranteed to be all in one vertical layer
-- All nodes before this vertical layer have to be placed in layers before we can proceed
longestPathAlgo :: (NodeClass n, EdgeClass e) => CGraph n e -> (CGraph n e, [[UINode]])
longestPathAlgo g =
  -- Debug.Trace.trace ("\nlongestPathAlgo\n" ++ show (g, newLayers, moveFinalNodesLeftToVert newLayers)) $
  --  Debug.Trace.trace ("\nlongestPathAlgo " ++ show g ++
  --                     "\nnewLayers" ++ show newLayers ++
  --                     "\nnodesWithoutChildren" ++ show nodesWithoutChildren ++
  --                     "\nverticalLayers" ++ show verticalLayers ++
  --                     "\noptionNodes" ++ show optionNodes ++
  --                     "\nnodesWithoutChildrenVertLayer" ++ show nodesWithoutChildrenVertLayer ++
  --                     "\n"++ showEdges g)
  (g, moveFinalNodesLeftToVert (map rmdups newLayers))
  where
    moveFinalNodesLeftToVert :: [[UINode]] -> [[UINode]]
    moveFinalNodesLeftToVert ls =
      -- Debug.Trace.trace ("nodesToMove "++ show (nodesToMove, nodesAndPrevious)) $
      (myhead 67 ls \\ nodesToMove) : (foldr insert (tail ls) nodesAndPrevious)
      where
        nodesToMove
          | length ls < 2 = []
          | otherwise = filter (notEl . VU.toList . parentsNoVertical g) (myhead 68 ls)
        notEl [n] = n `notElem` myhead 69 (tail ls)
        notEl _ = False
        insert (n, p) lays
          | null fpl = lays -- Debug.Trace.trace ("insert "++ show lays ++"\n\n"++ show (add lays (find p lays) n)) $
          | otherwise = add lays (head fpl) n
          where
            fpl = findn p lays
        nodesAndPrevious = zip nodesToMove (map (VU.head . parentsNoVertical g) nodesToMove)
        add list pos n = take (pos - 1) list ++ ((list !! (pos - 1)) ++ [n]) : (drop pos list)
        findn p l = [fst il | il <- zip [0 ..] l, p `elem` snd il]

    newLayers = layersrec (rmdups $ VU.toList nodesWithoutChildrenVertLayer) fil []
    fil = filter (not . null . sel2) verticalLayers
    sel1 (x, _, _) = x
    sel2 (_, y, _) = y
    ns = VU.map fromIntegral (VU.fromList (nodes g))
    nodesWithoutChildren = VU.filter (VU.null . cs) ns
    nodesWithoutChildrenVertLayer :: VU.Vector UINode
    nodesWithoutChildrenVertLayer =
      -- Debug.Trace.trace ("nwcvl "++ show (nodesWithoutChildren, nwcvl))
      nwcvl
      where
        nwcvl = VU.concatMap (findLayers (map sel1 verticalLayers)) nodesWithoutChildren
    findLayers :: [[UINode]] -> UINode -> VU.Vector UINode
    findLayers ls n
      | null ls = VU.singleton n
      | otherwise = VU.fromList (concat (map findL ls))
      where
        findL l
          | elem n l = l
          | otherwise = [n]
    cs node = Graph.children g node [dummyEdge Nothing 0]
    (_, optionNodes) = partitionNodes g ns -- nonOptionNodes
    verticalLayers =
      -- Debug.Trace.trace (show ("verticalLayers", VU.toList optionNodes, vLayers (VU.toList optionNodes))) $
      vLayers (VU.toList optionNodes)

    vLayers [] = []
    vLayers (n : ns1) =
      -- Debug.Trace.trace (show ("vLayers", n, newLayer, addUnconnectedChildren newLayer)) $
      (addUnconnectedChildren newLayer) : (vLayers (ns1 \\ newLayer))
      where
        newLayer = sort $ verticallyConnectedNodes g n
        addUnconnectedChildren :: [UINode] -> ([UINode], UnconnectedChildren, Bool)
        addUnconnectedChildren layer1 = (layer1, myNub $ VU.toList (VU.concat (map nonVertChildren layer1)), False)
        nonVertChildren node = childrenNoVertical g node

    -- the idea of this recursion is to go backwards from the final node and add non-vertical nodes that are fully connected at the input
    -- if there is only a vertical layer possible, add it
    layersrec :: [UINode] -> [([UINode], UnconnectedChildren, Bool)] -> [UINode] -> [[UINode]]
    layersrec curLayer vertLayers usedNodes
      | null curLayer -- Debug.Trace.trace "\n§§1 "
        =
        []
      | length usedNodes + length curLayer > length (nodes g) =
        Debug.Trace.trace
          ("\n§§2 " ++ show (curLayer, length usedNodes, usedNodes, length curLayer, length (nodes g)))
          [curLayer] -- should not happen
      | otherwise {-Debug.Trace.trace ("\n§§3 curLayer "++ show curLayer ++
                                     "\nfullyConnectedVertNodes2 " ++ show fullyConnectedVertNodes2 ++
                                     "\nnewCurLayerOrVert " ++ show newCurLayerOrVert ++
                                     "\nusedNodes " ++ show usedNodes ++
                                     "\nlayerParents curLayer " ++ show (layerParents curLayer) ++
                                     "\nvertLayers    " ++ show vertLayers ++
                                     "\nnewVertLayers " ++ show newVertLayers ++
                                     "\nfil" ++ show fil)-} =
        curLayer : (layersrec newCurLayerOrVert filtered (usedNodes ++ curLayer))
      where
        newVertLayers = map adjustConnected vertLayers
        adjustConnected (someLayer, unconnectedChildren, _) =
          -- Debug.Trace.trace ("adjustConnected " ++ show (someLayer, unconnectedChildren, newun, map (isNotMainFunctionArg g) someLayer)) $
          (someLayer, newun, null newun && all (isNotMainFunctionArg g) someLayer)
          where
            newun = unconnectedChildren \\ curLayer

        filtered
          | not (null newCurLayer) -- Debug.Trace.trace ("fil0 "++ show (newVertLayers)) $
            =
            filter (not . changed) newVertLayers
          | not (null fullyConnectedVertNodes2) -- Debug.Trace.trace ("fil1 "++ show (filter (not . isFullyConnected) newVertLayers)) $
            =
            filter (not . isFullyConnected) newVertLayers --remove fully connected vertical layers
          | otherwise -- Debug.Trace.trace ("fil2 "++ show (filter (not . isFullyConnected) newVertLayers)) $
            =
            filter (not . isFullyConnected) newVertLayers --remove fully connected vertical layers
            --        fullyConnectedVertNodes = concat (map fst (filter isFullyConnectedAndNotArg newVertLayers))
        fullyConnectedVertNodes2 = concatMap sel1 (filter isFullyConnected newVertLayers)
        --        isFullyConnectedAndNotArg (someLayer,unconnectedChildren) = Debug.Trace.trace ("isfully "++ show (null unconnectedChildren, map (isMainFunctionArg g) someLayer)) $
        --                                                                    null unconnectedChildren &&
        --                                                                    not (or (map (isMainFunctionArg g) someLayer))

        isFullyConnected (_someLayer, unconnectedChildren, _) = null unconnectedChildren

        newCurLayer =
          -- Debug.Trace.trace ("curParents"++ show (layerParents curLayer, filter shouldNodeBeAdded (layerParents curLayer))) $
          myNub (filter shouldNodeBeAdded (layerParents curLayer)) ++ concatMap sel1 (filter changed newVertLayers)
        changed (_, _, b) = b
        layerParents l = VU.toList (VU.concatMap (parentsNoVertical g) (VU.fromList l))
        newCurLayerOrVert
          | not (null newCurLayer) -- Debug.Trace.trace "not (null newCurLayer)" $ --prefer normal nodes to vertical nodes
            =
            myNub newCurLayer
          | not (null fullyConnectedVertNodes2) -- Debug.Trace.trace "not (null fullyConnectedVertNodes2)" $ --if no normal nodes are left
            =
            myNub fullyConnectedVertNodes2
          | otherwise = []
        shouldNodeBeAdded :: UINode -> Bool -- have all children been added, then node should be added
        shouldNodeBeAdded node
          | VU.null chs -- Debug.Trace.trace ("should0 "++ show (node, chs, VU.map isChildUsed chs)) $
            =
            False
          | otherwise -- Debug.Trace.trace ("should1 "++ show (node, chs, VU.map isChildUsed chs)) $
            =
            VU.and (VU.map isChildUsed chs)
              && not (isInVertLayer node)
          where
            chs = childrenNoVertical g node
            isChildUsed :: UINode -> Bool
            isChildUsed child = child `elem` (usedNodes ++ curLayer)
            isInVertLayer :: UINode -> Bool
            isInVertLayer n = any (elem n . sel1) vertLayers

-- Some functions don't have an input (e.g. True).
-- But a function without input can only appear directly after a case node
-- That's why we insert a connection node between this case node and the function node
addMissingInputNodes :: (NodeClass n, Show n, EdgeClass e) => CGraph n e -> CGraph n e
addMissingInputNodes graph =
  -- Debug.Trace.trace ("\naddConnectionNodes"++ show (foldl addConnNode graph (map fromIntegral (nodes graph)))) $
  foldl addConnNode graph (map fromIntegral (nodes graph))
  where
    addConnNode :: (NodeClass n, Show n, EdgeClass e) => CGraph n e -> UINode -> CGraph n e
    addConnNode g n
      | VU.null ps = g
      | isFunction graph n =
        --        && isCase graph (vhead 501 ps) -- Debug.Trace.trace ("caseconn"++ show (n, VU.head ps)) $

        insertConnNode g n (vhead 502 ps) Nothing 0
      | otherwise = g
      where
        ps = parentsNoVertical graph n

-- | partition nodes into non-vertically connected nodes and vertically connected nodes
partitionNodes :: EdgeClass e => CGraph n e -> VU.Vector UINode -> (VU.Vector UINode, VU.Vector UINode)
partitionNodes g =
  VU.partition
    ( \n ->
        VU.null (parentsVertical g n)
          && VU.null (childrenVertical g n)
    )

-- coffmanGrahamAlgo :: Graph -> [[Int]]
-- coffmanGrahamAlgo g =

addConnectionVertices :: (NodeClass n, Show n, EdgeClass e, Show e) => (CGraph n e, [[UINode]]) -> (CGraph n e, [[UINode]])
addConnectionVertices (g, ls) =
  -- Debug.Trace.trace ("acv"++ show (ls, addConnectionVs (g,ls))) $
  addConnectionVs (g, ls)

addConnectionVs :: (NodeClass n, Show n, EdgeClass e, Show e) => (CGraph n e, [[UINode]]) -> (CGraph n e, [[UINode]])
addConnectionVs (graph, []) = (graph, [])
addConnectionVs (graph, [l0]) = (graph, [l0])
addConnectionVs (graph, l0 : l1 : layers) = (fst adv, l0 : (snd adv))
  where
    adv = addConnectionVs (newGraph, (newLayer : layers))

    (newGraph, newLayer) = foldl dummyNodeEdge (graph, l1) (zip [(fromIntegral (m + 1)) ..] innerSs)
    m = maximum (nodes graph)

    innerSs = concatMap innerSegments l0
    innerSegments n =
      -- Debug.Trace.trace ("ps"++ show ps) $
      zip3 (repeat n) notInLayerL1Parents chans
      where
        notInLayerL1Parents = VU.toList (VU.filter isNotInLayerL1 ps)
        ps = parentsNoVertical graph n
        isNotInLayerL1 = not . (`elem` l1)
        chans = map (\e -> maybe (Nothing, 0) f e) edges
        f x = (channelNrIn (myhead 71 x), channelNrOut (myhead 72 x))
        edges = map (`lue` n) notInLayerL1Parents
        lue x y = Graph.lookupEdge (x, y) graph

    dummyNodeEdge :: (NodeClass n, Show n, EdgeClass e) => (CGraph n e, [UINode]) -> (UINode, (UINode, UINode, (Maybe Int, Int))) -> (CGraph n e, [UINode])
    dummyNodeEdge (g, l) (v, (from, to, (chanIn, chanOut))) =
      -- Debug.Trace.trace ("dummyNodeEdge"++ show (v,(from,to,chan)))
      (insertConnNode g from to chanIn chanOut, v : l)

insertConnNode :: (NodeClass n, Show n, EdgeClass e) => CGraph n e -> UINode -> UINode -> Maybe Channel -> Channel -> CGraph n e
insertConnNode graph from to chanIn chanOut =
  -- Debug.Trace.trace ("dummyNodeEdge"++ show (to, fromIntegral (m+1), chanIn, 0, chanOut, fromIntegral (m+1), from))
  Graph.deleteEdge (Just True) (to, from) $
    Graph.insertEdge (Just True) (to, fromIntegral (m + 1)) [dummyEdge chanIn 0] $
      Graph.insertEdge
        (Just True)
        (fromIntegral (m + 1), from)
        [dummyEdge Nothing chanOut]
        (Graph.insertNode (fromIntegral (m + 1)) connectionNode graph)
  where
    m = maximum (nodes graph)
    nest
      | isJust lu = Common.nestingFeatures (myFromJust 516 lu)
      | otherwise = Nothing
    lu = Graph.lookupNode from graph
    depth = maybe 1 Common.layer nest

-- UIEdge 2 1 "" Curly "#ff5863" "" i False False]

crossingReduction :: (NodeClass n, Show n, EdgeClass e, Show e) => Int -> Bool -> (CGraph n e, [[UINode]]) -> (CGraph n e, [[UINode]])
crossingReduction i longestP (graph, layers)
  | i > 0 -- Debug.Trace.trace ("crossingReduction\nlayers    " ++ show layers ++
  --         "\nc         "++ show c ++
  --         "\nnewlayers "++ show newLayers) $
    =
    crossingReduction (i - 1) longestP (graph, newLayers)
  | otherwise = (graph, layers)
  where
    -- nodes that are at the center of attention
    priorityNodes = VU.toList $ longestinfrequentPaths graph revLayers
    revLayers = reverse (map (map fromIntegral) layers)

    --  c = -- Debug.Trace.trace ("|r ") $ -- ++ show (layers, priorityNodes))
    --      (crossR graph LeftToRight (map (map fromIntegral) layers) priorityNodes longestP)
    --  newLayers = -- Debug.Trace.trace ("|l ") $ -- ++ show (layers, priorityNodes))
    --              map (map fromIntegral)
    --                  (reverse (crossR graph RightToLeft (reverse c) (reverse priorityNodes) longestP))

    c =
      -- Debug.Trace.trace ("|l ") $ -- ++ show (layers, priorityNodes))
      reverse (crossR graph RightToLeft (reverse (map (map fromIntegral) layers)) (reverse priorityNodes) longestP)

    newLayers =
      --      Debug.Trace.trace ("|r ") $ -- ++ show (layers, priorityNodes))
      map
        (map fromIntegral)
        (crossR graph LeftToRight c priorityNodes longestP)

crossR :: (NodeClass n, Show n, EdgeClass e, Show e) => CGraph n e -> Dir -> [[Int]] -> [Int] -> Bool -> [[Int]]
crossR _ _ [] _ _ = []
crossR g dir (l0 : l1 : layers) (n0 : n1 : ns) longestP
  | crossings l0Enum bEnum <= crossings l0Enum l1Enum =
    --          Debug.Trace.trace ("a0 " ++ show (dir,l0p, b, l1p, (n0:n1:ns), crossings l0Enum bEnum, crossings l0Enum l1Enum,l0,l1)
    --                                   ++ "\n   " ++ show (nl0,nl1)) $
    l0p : (crossR g dir (bv : layers) (n1 : ns) longestP)
  | otherwise -- map (lv g) $
  --        Debug.Trace.trace ("a1 " ++ show (dir,l0p, b, l1p,l0Enum,l1Enum,bEnum,crossings l0Enum bEnum,crossings l0Enum l1Enum)
  --                                 ++ "\n " ++ show (nl0,nl1)) $
    =
    l0p : (crossR g dir (l1p : layers) (n1 : ns) longestP)
  where
    nl0 = map fst (lv g l0)
    nl1 = map fst (lv g l1)
    --    isNoVert0 = not (or (map snd (lv g l0)))
    --    isNoVert1 = not (or (map snd (lv g l1)))
    b = barycenter g dir l0 l1 n1
    bv = map fst (lv g b)
    --    m = median     g nl0 nl1
    l0p
      | isJust (vertNum n0) || longestP = nl0
      | otherwise = nl0 -- n0 : (delete n0 nl0)
    l1p
      | isJust (vertNum n1) || longestP = nl1
      | otherwise = nl1 -- n1 : (delete n1 nl1)
    getY1 ((_, _, _, _), (y1, chan, _, _)) = (fromIntegral y1) * 10 + chan
    crossings en0 en1 =
      -- Debug.Trace.trace (if nl0 == [9] then "ee " ++ show (lexicographicSort ee) ++
      -- show (VU.map getY1 $ lexicographicSort ee) ++
      -- show (primitiveInversionCount (VU.map getY1 $ lexifromJustcographicSort ee)) else "") $
      primitiveInversionCount (VU.map getY1 $ lexicographicSort ee)
      where
        ee = VU.fromList (edgesEnum en0 en1 g dir (map fromIntegral nl0))
    l0Enum = IM.fromList (zip nl0 [0 ..])
    l1Enum = IM.fromList (zip nl1 [0 ..])
    bEnum = IM.fromList (zip b [0 ..])
    --    mEnum  = IM.fromList (zip m  [0..])

    lu n = Graph.lookupNode (fromIntegral n) g
    vertNum n = maybe Nothing Common.verticalNumber (lu n)
crossR _ _ ls ns _ = ls

-- arrange vertical nodes directly below each other,
-- returns Nothing if there are no vertical nodes in this layer
lv :: EdgeClass e => CGraph n e -> [Int] -> [(Int, Bool)]
lv _ [] = []
lv g (l : ls) =
  -- Debug.Trace.trace ("vertConnected "++ show ((l,ls,ls \\ vertConnected),(goUp ps),l,(goDown cs))) $
  vertConnected ++ (lv g (ls \\ (map fst vertConnected)))
  where
    vertConnected :: [(Int, Bool)]
    vertConnected
      | null up && null down = [(l, False)]
      | otherwise = map tr (up ++ [l] ++ down)
    tr ll = (ll, True)
    up = goUp ps
    down = goDown cs
    ps = map fromIntegral $ VU.toList $ parentsVertical g (fromIntegral l)
    goUp :: [Int] -> [Int]
    goUp n
      | null n = []
      | otherwise = goUp (map fromIntegral $ VU.toList $ parentsVertical g (fromIntegral (head n))) ++ [fromIntegral (head n)]

    cs = map fromIntegral $ VU.toList $ childrenVertical g (fromIntegral l)
    goDown :: [Int] -> [Int]
    goDown n
      | null n = []
      | otherwise = (fromIntegral (head n)) : (goDown (map fromIntegral $ VU.toList $ childrenVertical g (fromIntegral (head n))))

-- type YNode = (YPos,Channel,UINode,IsDummy)
edgesEnum :: (NodeClass n, EdgeClass e, Show e) => IM.IntMap UINode -> IM.IntMap UINode -> CGraph n e -> Dir -> [UINode] -> [(YNode, YNode)]
edgesEnum en0 en1 gr dir l0 = catMaybes edges
  where
    edges :: [Maybe (YNode, YNode)]
    edges = map (edge en0 en1) (edgesOfLayer gr l0)
    edge :: IM.IntMap UINode -> IM.IntMap UINode -> (UINode, UINode) -> Maybe (YNode, YNode)
    edge e0 e1 (src, tgt)
      | isNothing s || isNothing t = Nothing
      | otherwise =
        Just
          ( (myFromJust 517 s, chanNr, src, isDummy gr src),
            (myFromJust 518 t, 0, tgt, isDummy gr tgt)
          )
      where
        s = IM.lookup (fromIntegral src) e0
        t = IM.lookup (fromIntegral tgt) e1
        chanNr
          | isJust lu && null (myFromJust 519 lu) = 0
          | isJust lu = channelNrOut (myhead 73 (myFromJust 520 lu))
          | otherwise = 0
        lu = Graph.lookupEdge (tgt, src) gr

    edgesOfLayer :: EdgeClass e => CGraph n e -> [UINode] -> [(UINode, UINode)]
    edgesOfLayer g l = concatMap (adjEdges g) l
    adjEdges :: EdgeClass e => CGraph n e -> Word32 -> [(UINode, UINode)]
    adjEdges g n
      | leftToRight dir = map (n,) (VU.toList (parentsNoVertical g n))
      | otherwise = map (n,) (VU.toList (childrenNoVertical g n))

-- type YPos = Int
-- type YNode = (YPos,Channel,UINode,IsDummy)

isNotMainFunctionArg :: NodeClass n => CGraph n e -> UINode -> Bool
isNotMainFunctionArg g node =
  -- not (maybe False isMainArg (Graph.lookupNode node g))
  not (isMainArg g node)

-- Assign every node in l1 a number thats the barycenter of its neighbours in l0, then sort.
-- If the node is marked as a vertical node with a number, this number has precedence in sorting
barycenter :: (NodeClass n, Show n, EdgeClass e, Show e) => CGraph n e -> Dir -> [Int] -> [Int] -> Int -> [Int]
barycenter g dir l0 l1 _ =
  -- Debug.Trace.trace ("bary " ++ show (map bc l1, sortOn snd (map bc l1))) $
  map fst (sortOn snd (map bc l1))
  where
    bc :: Int -> (Int, Double)
    bc node =
      -- Debug.Trace.trace ("bc" ++ show (dir, node, ps, cs, l0, l1, nodeWeight dir))
      (node, nodeWeight dir)
      where
        lenCs = VU.length cs
        lenPs = VU.length ps
        cs = VU.map fromIntegral (childrenNoVertical g (fromIntegral node))
        ps = VU.map fromIntegral (parentsNoVertical g (fromIntegral node))
        nodeWeight :: Dir -> Double
        nodeWeight LeftToRight
          | isJust vertNum -- Debug.Trace.trace ("bvert lr "++ show vertNum)
            =
            (fromIntegral (myFromJust 521 vertNum)) + (if VU.null cs then 0 else (subPos (VU.head cs)) * 10000)
          | lenCs == 0 =
            -- Debug.Trace.trace "bry -1"
            (-1)
          --                | node == prioNode = -2
          | otherwise =
            -- Debug.Trace.trace ("bsum lr "++ show (VU.map xpos cs)) $
            ((VU.sum (VU.map xpos cs)) / (fromIntegral lenCs)) + (if VU.null cs then 0 else (subPos (VU.head cs)) * 10000)
        nodeWeight RightToLeft
          | isJust vertNum =
            -- Debug.Trace.trace ("bvert rl "++ show vertNum)
            (fromIntegral (myFromJust 522 vertNum)) + (if VU.null cs then 0 else (subPos (VU.head cs)) * 10000)
          | lenPs == 0 -- Debug.Trace.trace "bry -1"
            =
            (-1)
          --                | node == prioNode = -2
          | otherwise -- Debug.Trace.trace ("bsum rl "++ show (VU.map xpos ps)) $
            =
            ((VU.sum (VU.map xpos ps)) / (fromIntegral lenPs)) + (if VU.null cs then 0 else (subPos (VU.head cs)) * 10000)

        lu = Graph.lookupNode (fromIntegral node) g
        vertNum = maybe Nothing Common.verticalNumber lu
        xpos :: Int -> Double
        xpos c =
          -- Debug.Trace.trace (show (c, l0,maybe 0 fromIntegral (elemIndex c l0), subPos c)) $
          (maybe 0 fromIntegral (elemIndex c l0))

        subPos :: Int -> Double
        subPos c =
          -- Debug.Trace.trace (show channel ++ " : " ++ show channels) $
          (fromIntegral channel) / (fromIntegral channels)
          where
            channel = maybe 0 channelNrOut edgeLabel
            channels = maybe 1 nrTypes (Graph.lookupNode (fromIntegral c) g)
            nrTypes x
              | isSubLabel x = subLabels x
              | otherwise = 1
            edgeLabel
              | isNothing (Graph.lookupEdge dEdge g) = Nothing
              | null (myFromJust 523 (Graph.lookupEdge dEdge g)) = Nothing
              | otherwise = fmap (myhead 74) (Graph.lookupEdge dEdge g)
            dEdge = (fromIntegral node, fromIntegral c)

-- Assign every node in l0 a number thats the median of its neighbours in l1, then sort
median :: EdgeClass e => CGraph n e -> [Int] -> [Int] -> [Int]
median g l0 l1 = map fst $ sortOn snd $ map bc l0
  where
    bc :: Int -> (Int, Int)
    bc node = (node, if len == 0 then 0 else m VU.! (len `div` 2))
      where
        len = VU.length cs
        cs :: Vector Int
        cs =
          VU.map
            (\x -> fromMaybe 0 (elemIndex (fromIntegral x) l1))
            (childrenNoVertical g (fromIntegral node))
        m = VU.modify I.sort cs

--TODO: radix sort
--https://hackage.haskell.org/package/uvector-algorithms-0.2/docs/Data-Array-Vector-Algorithms-Radix.html

-- Sort two edges lexicographically after their y-position in the layer
-- An edge has two points, each point has a y-position (e.g. e0y0)
-- and a node number (e.g. e0n0)
lexicographicSort :: Vector (YNode, YNode) -> VU.Vector (YNode, YNode)
lexicographicSort es = VU.modify (I.sortBy lexicographicOrdering) es
  where
    lexicographicOrdering
      ((e0y0, e0n0, _, _), (e0y1, e0n1, _, _))
      ((e1y0, e1n0, _, _), (e1y1, e1n1, _, _))
        | (e0y0 > e1y0)
            || (e0y0 == e1y0 && e0n0 > e1n0)
            || (e0y0 == e1y0 && e0n0 == e1n0 && e0y1 > e1y1)
            || (e0y0 == e1y0 && e0n0 == e1n0 && e0y1 == e1y1 && e0n1 > e1n1) =
          GT
        | e0y0 == e1y0 && e0n0 == e1n0 && e0y1 == e1y1 && e0n1 == e1n1 = EQ
        | otherwise = LT

-- | See:  Simple and Efficient Bilayer Cross Counting by Barth, Mutzel, Jünger
primitiveInversionCount :: VU.Vector Int -> Int
primitiveInversionCount xs =
  sum
    [ if (xs VU.! i) > (xs VU.! j) then 1 else 0 | i <- [0 .. ((VU.length xs) - 1)], j <- [i .. ((VU.length xs) - 1)]
    ]

--  where l = VU.length xs

-- Modified merge sort for counting of edge crossings
-- which is the same as counting inversions (see)
-- http://www.geeksforgeeks.org/counting-inversions/

merge :: ([Int], Int) -> ([Int], Int) -> ([Int], Int)
merge ([], _) (ys, inv) = (ys, inv)
merge (xs, inv) ([], _) = (xs, inv)
merge (xs@(x : xt), inv0) (ys@(y : yt), inv1)
  | x <= y = (x : (fst (merge (xt, inv0) (ys, inv1))), inv0 + inv1)
  | otherwise = (y : (fst (merge (xs, inv0) (yt, inv1))), inv0 + inv1 + length xs)

split :: [a] -> ([a], [a])
split (x : y : zs) = let (xs, ys) = split zs in (x : xs, y : ys)
split [x] = ([x], [])
split [] = ([], [])

mergeSort :: ([Int], Int) -> ([Int], Int)
mergeSort ([], _) = ([], 0)
mergeSort ([x], _) = ([x], 0)
mergeSort (xs, _) =
  let (as, bs) = split xs -- num_inv
   in merge (mergeSort (as, 0)) (mergeSort (bs, 0))

-- https://hackage.haskell.org/package/splaytree
-- https://hackage.haskell.org/package/TreeStructures-0.0.1/docs/Data-Tree-Splay.html

fromAdj :: EdgeClass e => Map Word32 nl -> [(Word32, [Word32], [e])] -> Graph nl [e]
fromAdj nodesMap adj = foldl (newNodes nodesMap) Graph.empty adj
  where
    newNodes :: -- (Ord n, VU.Unbox n) =>
      EdgeClass e =>
      Map Word32 nl ->
      Graph nl [e] ->
      (Word32, [Word32], [e]) ->
      Graph nl [e]
    newNodes nm g (n, ns, eLabel) =
      Graph.insertEdges (Just True) edges $
        maybe id (Graph.insertNode (fromIntegral n)) (Map.lookup n nm) $
          Graph.insertNodes lookedUpNodes g
      where
        lookedUpNodes = mapMaybe addLabel ns
        addLabel n1 = fmap (n1,) (Map.lookup n nm)
        edges = zip es edgeLbls
        es = map (n,) ns
        edgeLbls = repeat eLabel

------------------------------------------------------------------------------------------------------------------------------

-- | To be able to jump vertically between nodes in an interactive ui
getColumns :: EdgeClass e => CGraphL n e -> (Map X [UINode], Map.Map Int [Column])
getColumns (gr, m) = (Map.fromList cols, Map.fromList (zip [0 ..] (divideTables cols)))
  where
    cols =
      map
        tupleWithX
        ( ( (map (sortBy sorty))
              . (groupBy groupx)
              . (sortBy sortx)
          )
            (map fromIntegral (Graph.nodes gr))
        )
    tupleWithX :: [UINode] -> (X, [UINode])
    tupleWithX ls = (maybe 0 fst (Map.lookup (myhead 504 ls) m), ls)
    groupx n0 n1 = maybe 0 fst (Map.lookup n0 m) == maybe 0 fst (Map.lookup n1 m)
    sortx n0 n1 = compare (maybe 0 fst (Map.lookup n0 m)) (maybe 0 fst (Map.lookup n1 m))
    sorty n0 n1 = compare (maybe 0 snd (Map.lookup n0 m)) (maybe 0 snd (Map.lookup n1 m))

    -- There can be several graphs on the screen that are connected with separating edges
    divideTables :: [Column] -> [[Column]]
    divideTables [] = []
    divideTables layers = layersWithoutSep : divideTables rest
      where
        (layersWithoutSep, rest) = sumLayers ([], layers)
        sumLayers :: ([Column], [Column]) -> ([Column], [Column])
        sumLayers (s, []) = (s, [])
        sumLayers (s, l : ls)
          | containsSeparatingEdge (snd l) = (s ++ [l], ls)
          | otherwise = sumLayers (s ++ [l], ls)
        containsSeparatingEdge ns = any cs ns
        cs n = VU.length (childrenSeparating gr n) > 0

-- | To be able to jump horizontally between nodes in an interactive ui
getRows :: CGraphL n e -> Map Y [UINode]
getRows (gr, m) =
  Map.fromList $
    map
      tupleWithY
      ( ( (map (sortBy sortx))
            . (groupBy groupy)
            . (sortBy sorty)
        )
          (map fromIntegral (Graph.nodes gr))
      )
  where
    tupleWithY :: [UINode] -> (Y, [UINode])
    tupleWithY ls = (maybe 0 snd (Map.lookup (myhead 504 ls) m), ls)
    groupy n0 n1 = maybe 0 snd (Map.lookup n0 m) == maybe 0 snd (Map.lookup n1 m)
    sortx n0 n1 = compare (maybe 0 fst (Map.lookup n0 m)) (maybe 0 fst (Map.lookup n1 m))
    sorty n0 n1 = compare (maybe 0 snd (Map.lookup n0 m)) (maybe 0 snd (Map.lookup n1 m))
