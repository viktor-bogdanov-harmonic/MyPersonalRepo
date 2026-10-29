SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE [dbo].[usp_fm_readonly_LiquidityPreviewByLots] 

@Date DATETIME,
@ShareholderRef NVARCHAR(50),
@ShareholderLocation NVARCHAR(255),
@IsRedemption BIT,
@TransferLiquidityTypeId INT,
@ParentShareClassID INT
AS

BEGIN

IF OBJECT_ID(N'tempdb..#ShareholderIds') IS NOT NULL   DROP TABLE #ShareholderIds
IF OBJECT_ID(N'tempdb..#TransInfo') IS NOT NULL   DROP TABLE #TransInfo
IF OBJECT_ID(N'tempdb..#ComplianceInfo') IS NOT NULL   DROP TABLE #ComplianceInfo
IF OBJECT_ID(N'tempdb..#FundIds') IS NOT NULL   DROP TABLE #FundIds
IF OBJECT_ID(N'tempdb..#FundInfo') IS NOT NULL   DROP TABLE #FundInfo
IF OBJECT_ID(N'tempdb..#GroupIds') IS NOT NULL   DROP TABLE #GroupIds
IF OBJECT_ID(N'tempdb..#GroupInfo') IS NOT NULL   DROP TABLE #GroupInfo
IF OBJECT_ID(N'tempdb..#ClassIds') IS NOT NULL   DROP TABLE #ClassIds
IF OBJECT_ID(N'tempdb..#ClassInfo') IS NOT NULL   DROP TABLE #ClassInfo
IF OBJECT_ID(N'tempdb..#SeriesIds') IS NOT NULL   DROP TABLE #SeriesIds
IF OBJECT_ID(N'tempdb..#SeriesInfo') IS NOT NULL   DROP TABLE #SeriesInfo
IF OBJECT_ID(N'tempdb..#NavInfo') IS NOT NULL   DROP TABLE #NavInfo
IF OBJECT_ID(N'tempdb..#FxRates') IS NOT NULL   DROP TABLE #FxRates

DECLARE @name nvarchar(255)
	SELECT 
		@name = convert(nvarchar(255), value) 
	FROM
		fn_listextendedproperty(default, default, default, default, default, default, default) 
	WHERE 
		name = 'FM_DatabaseName'  

DECLARE @IsJPMPEDB BIT = 0
	IF ISNULL(@name, '') = 'FM3JPMPE'
		SET @IsJPMPEDB = 1

SELECT DISTINCT
	sh.ShareholderID,
	l.SubDocCode AS AccountLocation,
	l.FM3InternalName AS AccountLocationName
INTO #ShareholderIds
FROM Shareholder sh
	INNER JOIN JPMAccountLocation l
		ON l.FM3InternalName = sh.CustomField2
	WHERE ISNULL((sh.ReferenceNum), '') = @ShareholderRef
	AND (l.JPMAccountLocationName = @ShareholderLocation OR (l.IsPBA = 1 AND @IsJPMPEDB = 1))

SELECT
	T.TransID,
	T.ShareholderID,
	n.ShareClassID,
	sc.ParentShareClassID,
	n.FundID,
	sh.AccountLocation,
	sh.AccountLocationName,
	CAST(MAX(CAST(ISNULL(ts.IgnoreLockup, 0) AS INT)) AS BIT) as IgnoreLockup	
INTO #TransInfo
FROM Trans T
	INNER JOIN #ShareholderIds sh 
		ON T.ShareholderID = sh.ShareholderID
	INNER JOIN NAV n 
		ON T.NAVID = n.NAVID
	INNER JOIN ShareClass sc 
		ON n.ShareClassID = sc.ShareClassID
	LEFT JOIN TransSub ts
		ON ts.TransID = T.TransID
WHERE T.TransTypeID IN (1, 3, 5) /*Subscription, Transfer In Crystal, Transfer In Uncrystal*/
	AND T.TransStatusID IN (2, 4) /*, Confirmed, Posted */
	AND T.TransDate <= @Date
	AND (@ParentShareClassID IS NULL OR sc.ParentShareClassID = @ParentShareClassID)
GROUP BY
	T.TransID,
	T.ShareholderID,
	n.ShareClassID,
	sc.ParentShareClassID,
	n.FundID,
	sh.AccountLocation,
	sh.AccountLocationName

CREATE TABLE #ComplianceInfo (
	TransID INT PRIMARY KEY,
	TransTypeID INT,
	TransSpecialTypeID INT,
	TransStatusID INT,
	TransDate DATETIME,
	InitialSubscriptionDate DATETIME,
	TransReportedDate DATETIME,
	ReferenceNum NVARCHAR(50),
	InitialCPS DECIMAL(28, 13),
	SharesLeft DECIMAL(28, 13),
	SharesLeftPending DECIMAL(28, 13),
	ContingentFee DECIMAL (28,13))

DECLARE @ShareholderID INT
DECLARE @ShareClassID INT

DECLARE ComplianceCursor CURSOR FOR
SELECT DISTINCT
	ShareholderID,
	ShareClassID
FROM
	#TransInfo

OPEN ComplianceCursor
FETCH NEXT FROM ComplianceCursor INTO @ShareholderID, @ShareClassID

WHILE @@FETCH_STATUS = 0
BEGIN
	INSERT #ComplianceInfo EXEC usp_fm_readonly_ComplianceDetails @ShareclassID, @ShareholderID, @Date, 0

	FETCH NEXT FROM ComplianceCursor INTO @ShareholderID, @ShareClassID
END 

CLOSE ComplianceCursor  
DEALLOCATE ComplianceCursor 

DELETE FROM #ComplianceInfo
WHERE SharesLeft + SharesLeftPending <= 0

DELETE t
FROM #TransInfo t
WHERE NOT EXISTS (
	SELECT c.TransID
	FROM #ComplianceInfo c
	WHERE c.TransID = t.TransID)

SELECT DISTINCT
	FundID
INTO #FundIds
FROM #TransInfo

SELECT
	f.FundID,
    MAX(CASE WHEN pt.Tag = 'JPMFundStatus' THEN pv.TreeValue ELSE '' END) AS FundStatus,
    CAST(MAX(CASE WHEN pt.Tag = 'JPMApplyLockupRulesToDividendReInvestments' AND pv.TreeValue IN ('1', 'yes') THEN 1 ELSE 0 END) AS BIT) AS FundApplyLockupRulesToDividendReInvestments,	
	MIN(oga.FMObjectGroupID) AS GroupID,
	f2.FundName
INTO #FundInfo
FROM #FundIds f
	LEFT OUTER JOIN 
	(
		ParameterTreeValue pv
		INNER JOIN ParameterTree pt
			ON pv.ParamTreeTypeID = pt.ParamTreeTypeID
			AND pv.ParamTreeID = pt.ParamTreeID
		INNER JOIN ParameterTreeType ptt
			ON pt.ParamTreeTypeID = ptt.ParamTreeTypeID
			AND ptt.ParameterTreeCategoryID = 3
	)
		ON f.FundID = pv.FMObjectID
	LEFT OUTER JOIN 
	(
		ObjectGroupAssoc oga
		INNER JOIN FMObjectGroup g
			ON oga.FMObjectGroupID = g.FMObjectGroupID
			AND g.IsPrimary = 1
	)
		ON f.FundID = oga.FMObjectID
	INNER JOIN v_fm_Funds f2
		ON f.FundID = f2.FundID

GROUP BY f.FundID, f2.FundName

SELECT DISTINCT
	GroupID
INTO #GroupIds
FROM #FundInfo
WHERE GroupID IS NOT NULL

SELECT
	g.GroupID,
	CAST(CASE WHEN LTRIM(RTRIM(MAX(CASE WHEN pt.Tag = 'JPMGroupFundTypeIPBExec' THEN pv.TreeValue ELSE '' END))) IN ('1', 'yes') THEN 1 ELSE 0 END AS BIT) AS FundTypeIPBExecutionOnly,
	CAST(CASE WHEN LTRIM(RTRIM(MAX(CASE WHEN pt.Tag = 'JPMGroupFundTypePBNon' THEN pv.TreeValue ELSE '' END))) IN ('1', 'yes') THEN 1 ELSE 0 END AS BIT) AS FundTypePBNonAdvisoryFund,
	CAST(CASE WHEN LTRIM(RTRIM(MAX(CASE WHEN pt.Tag = 'JPMGroupFundTypeJPMAAM' THEN pv.TreeValue ELSE '' END))) IN ('1', 'yes') THEN 1 ELSE 0 END AS BIT) AS FundTypeJPMAAMAdvisory,
	pvr.TreeValue AS ProductRiskRanking
INTO #GroupInfo
FROM #GroupIds g
	LEFT OUTER JOIN 
	(
		ParameterTreeValue pv
		INNER JOIN ParameterTree pt
			ON pv.ParamTreeTypeID = pt.ParamTreeTypeID
			AND pv.ParamTreeID = pt.ParamTreeID
		INNER JOIN ParameterTreeType ptt
			ON pt.ParamTreeTypeID = ptt.ParamTreeTypeID
			AND ptt.ParameterTreeCategoryID = 7
	)
		ON g.GroupID = pv.FMObjectID

	LEFT OUTER JOIN
	(
		ParameterTreeValue pvr
		INNER JOIN ParameterTree ptr
			ON pvr.ParamTreeTypeID = ptr.ParamTreeTypeID
			AND pvr.ParamTreeID = ptr.ParamTreeID
		INNER JOIN ParameterTreeType pttr
			ON ptr.ParamTreeTypeID = pttr.ParamTreeTypeID
			AND pttr.ParameterTreeCategoryID = 16
	)
		ON g.GroupID = pvr.FMObjectID
		AND ptr.Tag = 'JPMRiskRank'		
GROUP BY
	g.GroupID,
	pvr.TreeValue

SELECT DISTINCT
	ISNULL (ParentShareClassID, ShareClassID) AS ShareClassID
INTO #ClassIds
FROM #TransInfo

SELECT
	c.ShareClassID,
	sc.ShareClassName,
	sc.ShareDec,
	sc.NAVDec,
	sc.CurrencyID,
	rs.TradeDate1Freq1BaseID as SubscriptionRulesFrequencyBase,
	MAX(CASE WHEN pt.Tag = 'JPMClassMinRemainFund' THEN pv.TreeValue ELSE '' END) AS MinHoldingRemainInFund,
	MAX(CASE WHEN pt.Tag = 'JPMClassMinRemainFundDiscretionary' THEN pv.TreeValue ELSE '' END) AS MinimumRemainingDiscretionary,
	MAX(CASE WHEN pt.Tag = 'JPMClassMinRemainFund2' THEN pv.TreeValue ELSE '' END) AS MinimumHoldings2,
	MAX(CASE WHEN pt.Tag = 'JPMClassUSPBBrkInit' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS USPBBrokerageInitial,
	MAX(CASE WHEN pt.Tag = 'JPMClassUSPBBrkSub' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS USPBBrokerageSubsequent,
	MAX(CASE WHEN pt.Tag = 'JPMClassUSPBDiscInit' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS USPBDiscretionaryInitial,
	MAX(CASE WHEN pt.Tag = 'JPMClassUSPBDiscSub' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS USPBDiscretionarySubsequent,
	MAX(CASE WHEN pt.Tag = 'JPMClassNonUSPBBrkInit' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS NonUSPBBrokerageInitial,
	MAX(CASE WHEN pt.Tag = 'JPMClassNonUSPBBrkSub' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS NonUSPBBrokerageSubsequent,
	MAX(CASE WHEN pt.Tag = 'JPMClassNonUSPBDiscInit' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS NonUSPBDiscretionaryInitial,
	MAX(CASE WHEN pt.Tag = 'JPMClassNonUSPBDiscSub' AND @IsRedemption = 0 THEN pv.TreeValue ELSE '' END) AS NonUSPBDiscretionarySubsequent,
	CASE WHEN ISNULL(@IsRedemption, 1) = 1 THEN '' ELSE CASE WHEN r.IsAuthorized = 1 THEN 'Yes' ELSE 'No' END END AS TransferAuthorized,
	rPlatform.HardLockupMonths AS PlatformTrfHardLockupMonths,
	rCbo.HardLockupMonths AS LegalCBOTrfHardLockupMonths,
	rNcbo.HardLockupMonths AS LegalNCBOTrfHardLockupMonths,
	rPlatform.IsHoldbackTransferable AS HoldbackTransferable
INTO #ClassInfo
FROM #ClassIds c
	INNER JOIN ShareClass sc
		ON sc.ShareClassID = c.ShareClassID
	LEFT OUTER JOIN 
	(
		ParameterTreeValue pv
		INNER JOIN ParameterTree pt
			ON pv.ParamTreeTypeID = pt.ParamTreeTypeID
			AND pv.ParamTreeID = pt.ParamTreeID
		INNER JOIN ParameterTreeType ptt
			ON pt.ParamTreeTypeID = ptt.ParamTreeTypeID
			AND ptt.ParameterTreeCategoryID = 9
	)
		ON c.ShareClassID = pv.FMObjectID	
	LEFT OUTER JOIN JPMClassLiquidityRule r
		ON c.ShareClassID = r.ShareClassID
		AND @TransferLiquidityTypeId = r.JPMLiquidityTypeID
	LEFT OUTER JOIN JPMClassLiquidityRule rs
		ON c.ShareClassID = rs.ShareClassID
		AND rs.JPMLiquidityTypeID = 3 -- Subscription rules
	LEFT OUTER JOIN JPMClassLiquidityRule rPlatform
		ON c.ShareClassID = rPlatform.ShareClassID
		AND rPlatform.JPMLiquidityTypeID = 2 -- Platform Transfer
	LEFT OUTER JOIN JPMClassLiquidityRule rCbo
		ON c.ShareClassID = rCbo.ShareClassID
		AND rCbo.JPMLiquidityTypeID = 4 -- CBO Transfer
	LEFT OUTER JOIN JPMClassLiquidityRule rNcbo
		ON c.ShareClassID = rNcbo.ShareClassID
		AND rNcbo.JPMLiquidityTypeID = 5 -- NCBO Transfer
GROUP BY
	c.ShareClassID,
	r.IsAuthorized,
	sc.ShareClassName,
	sc.ShareDec,
	sc.NAVDec,
	sc.CurrencyID,
	rs.TradeDate1Freq1BaseID,
	rPlatform.HardLockupMonths,
	rCbo.HardLockupMonths,
	rNcbo.HardLockupMonths,
	rPlatform.IsHoldbackTransferable

SELECT DISTINCT
	ShareClassID,
	ParentShareClassID
INTO #SeriesIds
FROM #TransInfo

SELECT
	c.ShareClassID,
	sc.ShareClassName,
	MAX(i.SecurityCode) AS Valoren,
	MAX(ic.SecurityCode) AS CUSIP,
	sc.IsPreliminary,
	sc.IsJPMPBAHoldbackSeries,
	CASE WHEN MAX(ISNULL(hc.JPMHoldbackCUSIPID, -1)) > 0 THEN 1 ELSE 0 END AS IsPBAHoldbackSeries,
	CASE WHEN ISNULL(pv.TreeValue, '') = '090' THEN 1 ELSE 0 END AS IsIPBHoldbackSeries
INTO #SeriesInfo
FROM #SeriesIds c
	INNER JOIN ShareClass sc
		ON sc.ShareClassID = c.ShareClassID
	LEFT OUTER JOIN 
	(
		ParameterTreeValue pv
		INNER JOIN ParameterTree pt
			ON pv.ParamTreeTypeID = pt.ParamTreeTypeID
			AND pv.ParamTreeID = pt.ParamTreeID
			AND pt.Tag = 'JPMSeriesOlympicID'
		INNER JOIN ParameterTreeType ptt
			ON pt.ParamTreeTypeID = ptt.ParamTreeTypeID
			AND ptt.ParameterTreeCategoryID = 11
	)
		ON c.ShareClassID = pv.FMObjectID	
	LEFT OUTER JOIN ShareClassIdentifiers i
		ON sc.ShareClassID = i.ShareClassID
		AND i.IdentifierTypeID = 17				
	LEFT OUTER JOIN ShareClassIdentifiers ic
		ON sc.ShareClassID = ic.ShareClassID
		AND ic.IdentifierTypeID = 5
	LEFT OUTER JOIN JPMHoldbackCUSIP hc
		ON hc.ShareClassID = sc.ParentShareClassID
		AND ISNULL(ic.SecurityCode, '') <> ''
		AND (ic.SecurityCode = hc.Cusip OR ic.SecurityCode = hc.NonAdvCusip)
		
GROUP BY c.ShareClassID, sc.ShareClassName, sc.IsPreliminary, sc.IsJPMPBAHoldbackSeries, pv.TreeValue

SELECT
	n.FundID,
	s.ShareClassID,
	n.NAVDate,
	n.PriceDate,
	ISNULL (n.NNAV, 0) AS NNAV,
	ISNULL (n.GNAV, 0) AS GNAV,
	q.Quality as NAVQuality
INTO #NavInfo
FROM #SeriesIds s
	LEFT OUTER JOIN
	(
		NAV n 
		LEFT JOIN NAV n2
			ON n2.ShareClassID = n.ShareClassID
			AND n2.NAVDate <= @Date
			AND (n2.NAVDate > n.NAVDate OR (n2.NAVDate = n.NAVDate AND n2.NAVTypeID < n.NAVTypeID))
		INNER JOIN NAVQuality q
			ON q.QualityID = n.QualityID
	)
		ON n.ShareClassID = s.ShareClassID
		AND n.NAVDate <= @Date
WHERE n2.NAVID IS NULL

SELECT
	T.ShareclassID,
	ISNULL(
		MAX(CASE WHEN fxr.FundID IS NOT NULL THEN fxr.Rate END), -- Use rate with FundID if possible
		MAX(fxr.Rate)
		) AS Rate 
INTO #FxRates
FROM
(
	SELECT
		n.ShareclassID,
		n.FundID,
		c.CurrencyID,
		MAX(r.[Date]) AS RateDate
	FROM #NavInfo n
	INNER JOIN #SeriesIds s
		ON n.ShareClassID = s.ShareClassID
	INNER JOIN #ClassInfo c
		ON ISNULL(s.ParentShareClassID, s.ShareClassID) = c.ShareClassID
	INNER JOIN FXRate r
		ON r.[Date] < DATEADD(Day, 1, n.NAVDate)
		AND (r.FundID IS NULL OR r.FundID = n.FundID)
		AND r.ToCurrencyID = 4 -- USD
		AND r.FromCurrencyID = c.CurrencyID
		AND r.FXRateTypeID = 1
	GROUP BY 
		n.ShareclassID,
		n.FundID,
		c.CurrencyID
) T
INNER JOIN FXRate fxr
	ON (fxr.FundID IS NULL OR fxr.FundID = T.FundID)
	AND fxr.[Date] = T.RateDate
	AND fxr.ToCurrencyID = 4 -- USD
	AND fxr.FromCurrencyID = T.CurrencyID
	AND fxr.FXRateTypeID = 1
GROUP BY T.ShareclassID


SELECT
	t.TransID,
	t.FundID,
	t.ParentShareClassID,
	t.ShareClassID,
	t.AccountLocation,
	t.AccountLocationName,
	f.FundStatus,
	f.FundName,
	g.FundTypeIPBExecutionOnly,
	g.FundTypePBNonAdvisoryFund,
	g.FundTypeJPMAAMAdvisory,
	g.ProductRiskRanking,
	sc.ShareClassName as ClassName,
	sc.ShareDec,
	sc.NAVDec,
	sc.CurrencyID,
	sc.SubscriptionRulesFrequencyBase,
	sc.MinHoldingRemainInFund,
	sc.MinimumRemainingDiscretionary,
	sc.MinimumHoldings2,
	sc.USPBBrokerageInitial,
	sc.USPBBrokerageSubsequent,
	sc.USPBDiscretionaryInitial,
	sc.USPBDiscretionarySubsequent,
	sc.NonUSPBBrokerageInitial,
	sc.NonUSPBBrokerageSubsequent,
	sc.NonUSPBDiscretionaryInitial,
	sc.NonUSPBDiscretionarySubsequent,
	sc.TransferAuthorized,
	sc.PlatformTrfHardLockupMonths,
	sc.LegalCBOTrfHardLockupMonths,
	sc.LegalNCBOTrfHardLockupMonths,
	sc.HoldbackTransferable,
	s.ShareClassName as SeriesName,
	s.Valoren,
	s.CUSIP,
	CASE
		WHEN s.IsPreliminary = 1 THEN 'Prel'
		WHEN s.IsJPMPBAHoldbackSeries = 1 THEN 'HB'
		WHEN s.IsPBAHoldbackSeries = 1 THEN 'HB'
		WHEN s.IsIPBHoldbackSeries = 1 THEN 'HB'
		ELSE 'Mainline'
	END AS SeriesType,
	n.PriceDate,
	n.NAVDate,
	n.NNAV,
	n.GNAV,
	ISNULL(r.Rate, 1) AS FXRate,
	n.NAVQuality,
	c.TransSpecialTypeID,
	DATEADD(dd, DATEDIFF(dd, 0, ISNULL(c.InitialSubscriptionDate, c.TransDate)), 0) AS LotDate,
	c.SharesLeft + c.SharesLeftPending AS SharesLeft,
	CASE WHEN t.IgnoreLockup = 1 AND f.FundApplyLockupRulesToDividendReInvestments = 0 THEN 1 ELSE 0 END AS IgnoreLockup 
FROM #TransInfo t
	INNER JOIN #FundInfo f
		ON f.FundID = t.FundID
	LEFT JOIN #GroupInfo g
		ON f.GroupID = g.GroupID
	INNER JOIN #ClassInfo sc
		ON ISNULL(t.ParentShareClassID, t.ShareClassID) = sc.ShareClassID
	INNER JOIN #SeriesInfo s
		ON t.ShareClassID = s.ShareClassID
	INNER JOIN #NavInfo n
		ON t.ShareClassID = n.ShareClassID
	INNER JOIN #ComplianceInfo c
		ON c.TransID = t.TransID
	LEFT JOIN #FxRates r
		ON n.ShareclassID = r.ShareclassID

END
