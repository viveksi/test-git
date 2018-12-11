USE [MPNG]
GO
/****** Object:  StoredProcedure [dbo].[usp_MPUser_UpdateUser]    Script Date: 11/12/2018 04:35:55 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/* Change History :
** Peter Ahn 13 Nov 2014 Populates PermissionFields for SEA 		
** Peter Ahn 24 Nov 2014 Removed where clause for RoleID 77 FBM summary		
** Ryan Levita 26 May 2015 Change name and email fields from varchar to nvarchar to support unicode
** Cheong 23/10/2015 : TFS15922 - Add logging features on Users Table
** Peter Ahn 2017-03-07: making default to mp7 for ANZ - but this update won't change MP version
** M. Orechkine 2017-08-16 Remove hardcoded IDs. Daas source system 20 is also regarded as ANZ user
** Peter Ahn 2018-10-09 Retain hidden roles (126,127) Buzz Cluster Charts, User Feeds
** Vivek Singh 2018-11-07 removed User Feeds from not condition
** Vivek Singh 2018-11-15 removed New Analytics(125) from not condition
** Akhil Biswas 2018-12-07 SQDC3-308 prevent deleting  the hidden roles 129 from userrolesjoins table
*/
ALTER PROCEDURE [dbo].[usp_MPUser_UpdateUser]
	@userid INT,
	@usertype VARCHAR(50),
	@displayname NVARCHAR(500),
	@company VARCHAR(500),
	@countryid INT,
	@email NVARCHAR(500),
	@logo VARCHAR(100),
	@username NVARCHAR(320),
	@password VARCHAR(50),
	@deliverysetid INT,
	@ip VARCHAR(50),
	@maxusers INT,
	@active INT,
	@trial INT,
	@altcontact INT,
	@accmanid INT,
	@accteamid INT,
	@altname NVARCHAR(500),
	@altphone VARCHAR(50),
	@altemail NVARCHAR(500),
	@roleids VARCHAR(5000),
	@loginpage VARCHAR(50),
	@ContentDelivery NVARCHAR(20) = '0',
	@mpversion INT = 7,
	@StartPage VARCHAR(1000) = '',
	@isEnable BIT,
	@SourceSystemIDDel INT = 1,
	@ModifiedBy VARCHAR(20) = ''
 AS

SET NOCOUNT ON
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED

DECLARE 
	@isConcurrent INT, 
	@isIP INT,
	@customernumber VARCHAR(20),
	@timezonekey VARCHAR(255)

IF @usertype = 'Pro' BEGIN
	SELECT @isConcurrent = 0, @maxusers = 1
END	ELSE BEGIN
	SELECT @isConcurrent = 1
END

IF @usertype = 'IP' BEGIN
	SELECT @isIP = 1, @username = @ip
END	ELSE BEGIN
	SELECT @isIP = 0	
END

IF @usertype = 'Connect' BEGIN
	SELECT @isConcurrent = 0, @maxusers = 1, @mpversion = '5', @isIP = 0
END	

IF LEN(@StartPage) <= 0
	SELECT @StartPage = StartPage FROM Users WHERE UserID = @userid
	
SELECT @customernumber = c.customernumber FROM mmglobal..company c INNER JOIN mmglobal..deliverysets ds ON ds.companyid = c.companyid and ds.deliverysetid = @deliverysetid	

SELECT @timezonekey = ct.TimezonesTZKey FROM mmglobal..countries ct WHERE ct.countryID = @countryid

IF NOT EXISTS (SELECT * FROM Users WHERE Username = @username ANd UserID != @userid) BEGIN
	UPDATE Users SET 
		DisplayName = @displayname,
		DivisionName = @Company,
		CountryID = @CountryID,
		UserName = @username, 
		[Password] = dbo.ufn_MPNGEncryptString(@password),
		DeliverySetId = @deliverysetid, 
		Email = @email, 
		Logo = @logo, 
		ContactName = @altname, 
		ContactPhone = @altphone, 
		ContactEmail = @altemail, 
		Active = @active, 
		Trial = @trial, 
		CanContact = @altcontact, 
		CustomerNumber = @customernumber, 
		AccountManagerID = @accmanid, 
		AccountTeamID = @accteamid, 
		ConcurrentUsrs = @maxusers, 
		IsConcurrentUser = @isConcurrent, 
		IPUser = @isIP,
		LoginPage = @loginpage,
		TimezonesTZKey = @timezonekey,
		ContentDelivery = @ContentDelivery,
		--MPVersion = @mpversion,
		StartPage = @StartPage,
		isEnableMP45Toggle = @isEnable,
		ModifiedDate = GETDATE(), 
		ModifiedBy = @ModifiedBy
	WHERE UserID = @UserID
	
	CREATE TABLE #RoleID(RoleID INT)
	
	INSERT INTO #RoleID(RoleID)
	EXEC usp_MPNG_ListToIntTable @RoleIDs
		
	DECLARE @IsANZ BIT = 1
 
	SELECT 
		@IsANZ = CASE WHEN SystemGroup = 'ANZ' THEN 1 ELSE 0 END
	FROM 
		MMGlobal.dbo.DeliverySets ds
		JOIN MMGlobal.dbo.SourceSystem ss ON ss.SourceSystemID = ds.SourceSystemID
	WHERE 
		ds.DeliverySetID = @deliverysetid

	IF @IsANZ = 1 BEGIN
		if Not Exists (select * FROM #RoleID WHERE RoleID = 110) BEGIN
			INSERT INTO #RoleID(RoleID)
			SELECT 110
		END
	END

	-- get the Package role
	DECLARE @OldPackageRoleID INT = 0
	SELECT TOP 1 @OldPackageRoleID = RoleID from mpng.dbo.userrolesjoin j
	WHERE userID = @UserID And j.RoleID IN (100, 101, 102, 110)
  
	-- Logging
	INSERT INTO UserRolesJoinLog ([Action], RoleID, UserID, ModifiedDate, ModifiedBy)
	SELECT 'REMOVED', UserRolesJoin.RoleID, @UserID, GETDATE(), @ModifiedBy
	FROM UserRolesJoin
	WHERE UserRolesJoin.UserID = @UserID
		And NOT EXISTS (SELECT 0 FROM #RoleID R
				WHERE UserRolesJoin.RoleID = R.RoleID)
	UNION ALL
	SELECT 'ADDED', R.RoleID, @UserID, GETDATE(), @ModifiedBy
	FROM #RoleID R
	WHERE NOT EXISTS (SELECT 0 FROM UserRolesJoin
				WHERE UserRolesJoin.UserID = @UserID
					And R.RoleID = UserRolesJoin.RoleID)
	
	DELETE FROM userrolesjoin WHERE UserID = @UserID AND RoleID NOT IN (SELECT RoleID FROM mpng.dbo.Roles WHERE RoleGroupID = 6 AND RoleID != 110) 
	
	INSERT INTO userrolesjoin (userid, roleid)
	SELECT @UserID, roleid FROM #roleid --where roleid not in (77)
	
	DROP TABLE #RoleID


	--Populate PermissionFields 
	INSERT INTO MPNG.dbo.CoverageDisplayFieldUser(UserID, CoverageDisplayFieldID, SortOrder, Visible)
	SELECT @UserID,map.CoverageDisplayFieldID,1,1
	FROM [Permissions] P
		INNER JOIN RolesPermissionJoin RPJ ON P.PermissionID = RPJ.PermissionID
		INNER JOIN UserRolesJoin URJ ON RPJ.RoleID = URJ.RoleID
		INNER JOIN dbo.PermissionFieldOutputJoin pfo ON pfo.PermissionID = p.PermissionID
		INNER JOIN dbo.CoverageDisplayPermissionMapping map ON map.PermissionFieldID = pfo.PermissionFieldID AND map.IsANZ = @IsANZ
		LEFT Join CoverageDisplayFieldUser cu ON cu.CoverageDisplayFieldID = map.CoverageDisplayFieldID and cu.UserID = @UserID
	WHERE URJ.UserID = @UserID
		AND cu.CoverageDisplayFieldID IS NULL
	GROUP By map.CoverageDisplayFieldID, cu.CoverageDisplayFieldID	
	
	SELECT @UserID AS UserID, companyid FROM MMGlobal..deliverysets WHERE DeliverysetID = @deliverysetid
END ELSE BEGIN
	SELECT '' AS UserID, companyid FROM MMGlobal..deliverysets WHERE DeliverysetID = @deliverysetid
END

