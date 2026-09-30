/*==============================================================================
  Scripts/DatabaseCreation.sql
  Creates the SchoolManagementDB database if it does not already exist.
  Run against master (or any server connection without -d).
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_ID(N'SchoolManagementDB') IS NULL
BEGIN
    PRINT 'Creating database SchoolManagementDB...';
    CREATE DATABASE SchoolManagementDB;
END
ELSE
BEGIN
    PRINT 'Database SchoolManagementDB already exists.';
END
GO