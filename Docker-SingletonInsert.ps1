Clear-Host
docker ps -a -q | ForEach-Object { docker rm -f $_ }
Get-Job | Stop-Job
Get-Job | Remove-Job
 
$HostBaseDirectory = "D:/mssql-data"
erase D:/mssql-data*/*

$MaxContainers     = 24 
$CpuSets           = @( "0,1"  , "2,3"  , "4,5"  , "6,7"  , "8,9"  , "10,11", "12,13", "14,15", "16,17", "18,19",
                        "20,21", "22,23", "24,25", "26,27", "28,29", "30,31", "32,33", "34,35", "36,37", "38,39",
                        "40,41", "42,43", "44,45", "46,47" )
$Key               = "SPID"
 
for($i=0; $i -lt $MaxContainers; $i++) {
    $CpuSet = $CpuSets[$i]
 
    $DockerCmd = "docker run -v " + $HostBaseDirectory + $i + ":/mssql-data --cpuset-cpus=$CpuSet -e `"ACCEPT_EULA=Y`" -e `"MSSQL_SA_PASSWORD=P@ssw0rd!`" " +`
                 "-p " + [string](60000 + $i) + ":1433 --name SqlLinux$i -d microsoft/mssql-server-linux:2017-latest"
    $DockerCmd
    Invoke-Expression $DockerCmd
}
 
Start-Sleep -s 20
 
for($i=0; $i -lt $MaxContainers; $i++) {
    $DockerCmd = "docker exec -it SqlLinux$i /opt/mssql-tools/bin/sqlcmd "                                  +`
                 "-S localhost -U SA -P `"P@ssw0rd!`" "                                                     +`
                 "-Q `"CREATE DATABASE SingletonInsert "                                                    +`
                      "ON PRIMARY "                                                                         +`
                      "( NAME = `'SingletonInsert`', FILENAME = N`'/mssql-data/SingletonInsert.mdf`', "     +` 
                      "  SIZE = 256MB , FILEGROWTH = 256MB ) "                                              +`
                      "LOG ON "                                                                             +`
                      "( NAME = N`'SingletonInsert_log`', FILENAME = N`'/mssql-data/SingletonInsert.ldf`'," +` 
                      "  SIZE = 256MB , FILEGROWTH = 256MB );"                                              +`
                      "ALTER DATABASE SingletonInsert SET DELAYED_DURABILITY=FORCED`""
        
    $DockerCmd
 
    Invoke-Expression $DockerCmd
 
    if ($Key -eq "GUID") {
        $DockerCmd = "docker exec -it SqlLinux$i /opt/mssql-tools/bin/sqlcmd "              +`
                     "-S localhost -d SingletonInsert -U SA -P `"P@ssw0rd!`" "              +`
                     "-Q `"CREATE TABLE [dbo].[si] ( "                                      +`
                          "    c1 UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY );`""
    }
    else {
        $DockerCmd = "docker exec -it SqlLinux$i /opt/mssql-tools/bin/sqlcmd "              +`
                     "-S localhost -d SingletonInsert -U SA -P `"P@ssw0rd!`" "              +`
                     "-Q `"CREATE TABLE [dbo].[si] ( c1 BIGINT NOT NULL );`""
    }
                           
    Write-Host "Creating table" -ForegroundColor Red
    Invoke-Expression $DockerCmd
 
    if ($Key -eq "GUID") {
        $DockerCmd = "docker exec -it SqlLinux$i /opt/mssql-tools/bin/sqlcmd "              +`
        "-S localhost -d SingletonInsert -U SA -P `"P@ssw0rd!`" "                           +`
        "-Q `"CREATE PROCEDURE [dbo].[usp_Insert] AS "                                      +`
             "BEGIN "                                                                       +`
             "    SET NOCOUNT ON "                                                          +`
             "    DECLARE @i INTEGER = 0; "                                                 +`
             "    WHILE @i < 250000 "                                                       +`
             "    BEGIN "                                                                   +`
             "        INSERT INTO si DEFAULT VALUES; "                                      +`
             "        SET @i += 1; "                                                        +`
             "    END; "                                                                    +`
             "END;`""
    } 
    else
    {
        $DockerCmd = "docker exec -it SqlLinux$i /opt/mssql-tools/bin/sqlcmd "              +`
        "-S localhost -d SingletonInsert -U SA -P `"P@ssw0rd!`" "                           +`
        "-Q `"CREATE PROCEDURE [dbo].[usp_Insert] AS "                                      +`
             "BEGIN "                                                                       +`
             "    SET NOCOUNT ON "                                                          +`
             "    DECLARE  @i    INTEGER = 0 "                                              +`
             "            ,@base BIGINT  = @@SPID * 10000000000;"                           +`
            "    WHILE @i < 250000 "                                                        +`
             "    BEGIN "                                                                   +`
             "        INSERT INTO si VALUES (@base + @i); "                                 +`
             "        SET @i += 1; "                                                        +`
             "    END; "                                                                    +`
             "END;`""
    }

    Write-Host "Creating stored procedure" -ForegroundColor Red
    Invoke-Expression $DockerCmd
}
 
$RunWorkload = { 
    param ($LoopIndex)
    $DockerCmd = "docker exec SqlLinux$LoopIndex /opt/mssql-tools/bin/sqlcmd " +`
                 "-S localhost -U sa -P `'P@ssw0rd!`' -d SingletonInsert " +`
                 "-Q `'EXEC usp_Insert`'"
    $DockerCmd
    Invoke-Expression $DockerCmd
}

$TruncateTable = { 
    param ($LoopIndex)
    $DockerCmd = "docker exec SqlLinux$LoopIndex /opt/mssql-tools/bin/sqlcmd " +`
                 "-S localhost -U sa -P `'P@ssw0rd!`' -d SingletonInsert " +`
                 "-Q `'TRUNCATE TABLE si`'"
    $DockerCmd
    Invoke-Expression $DockerCmd
}
 
$InsertRates = @()
 
for($i=0; $i -lt $MaxContainers; $i++) {
    for($j=0; $j -lt ($i + 1); $j++) {
        Start-Job -ScriptBlock $TruncateTable -ArgumentList $j
    }
    while (Get-Job -state running) { Start-Sleep -Milliseconds 10 }

    $StartMs = Get-Date
 
    for($j=0; $j -lt ($i + 1); $j++) {
        Start-Job -ScriptBlock $RunWorkload -ArgumentList $j
    }
    while (Get-Job -state running) { Start-Sleep -Milliseconds 10 }
 
    $EndMs = Get-Date
 
    $InsertRate = (($i + 1) * 250000 * 1000)/(($EndMs - $StartMs).TotalMilliseconds) 
    Write-Host "Insert rate for " $j " containers = " $InsertRate
    $InsertRates += $InsertRate
}
 
Clear-Host
 
for($i=0; $i -lt $MaxContainers; $i++) {
    Write-Host "Inserts`/s using " ($i + 1) " containers = " $InsertRates[$i]
}