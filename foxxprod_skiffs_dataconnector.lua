dofile('./interface/interface.lua');
dofile('./interface/adv.lua');
dofile('./interface/device.lua');


-- Information : Num�ro de Version, Nom, Interface
function device.GetInformation()
	return { version = 2.7, name = 'FOXX PROD TV - DATACONNECTOR', class = 'display', interface = {} };
end	

-- Configuration du Device
function device.OnConfiguration(node)
	wndPresentation.ShowModalConfig(node);
end

-- Ouverture
function device.OnInit(params)

	-- Connexion Base MySQL "tv"
	device.dbTV = sqlBase.ConnectMySQL('localhost', 'foxxprod', 'root', '', 3306);
	if device.dbTV == nil then
		-- Creation Base TV
		local base = sqlBase.Clone();
		base:Query("CREATE DATABASE foxxprod");
		base:Delete();
		
		device.dbTV = sqlBase.ConnectMySQL('localhost', 'foxxprod', 'root', '', 3306);
		if device.dbTV == nil then
			adv.Error("Erreur Connexion Base foxxprod");
			return;
		end
		-- Creation des Tables 
		if device.dbTV:ScriptSQL('./process/base_tv.sql') == true then
			adv.Success("Creation Base foxxprod OK");
		else
			adv.Error("Erreur Connexion Base foxxprod");
			return;
		end
	end
	device.dbTV:Load();
	
	-- Tableau de Bord
	tbNavigation = wnd.CreateAuiToolBar({ style = auiToolBarStyle.HORIZONTAL });

	local btn_startlist = tbNavigation:AddTool("Liste de D�part", "./res/32x32_order.png");
	local btn_ranking = tbNavigation:AddTool("Classement", "./res/32x32_ranking.png");

	tbNavigation:AddSeparator();
	modeLabel = wnd.CreateStaticText({parent = tbNavigation, label = "Mise a jour de la startlist" });
	tbNavigation:AddControl(modeLabel);
	tbNavigation:Realize();

	local mgr = app.GetAuiManager();
	mgr:AddPane(tbNavigation, { toolbarpane=true, direction='top', caption = 'FoxxProd', gripper=true });
	mgr:Update();

	-- Prise des Evenements (Bind)
	tbNavigation:Bind(eventType.MENU, OnModeClear, btn_clear);
	tbNavigation:Bind(eventType.MENU, OnModeStartlist, btn_startlist);
	tbNavigation:Bind(eventType.MENU, OnModeRanking, btn_ranking);
	

	-- Prise valeur offset Horloge PC - Horloge Chrono Officielle
	local rc, offsetInfo = app.SendNotify('<offset_time_load>');
	assert(rc);
	device.offset = tonumber(offsetInfo.offset);

	-- R�cup�ration des infos de la course
	local rc, raceInfo = app.SendNotify('<race_load>');
	assert(rc);
	device.raceInfo = raceInfo;
	app.GetAuiMessage():AddLine("Manche = "..device.raceInfo.Code_manche.." / Inter = "..device.raceInfo.Nb_inter);

	-- Prise Information Coureur ayant le meilleur 
	local rc, best_time = app.SendNotify('<best_time_load>');
	device.OnNotifyBestTime('<best_time>', best_time);
	
	-- Prise des coureurs en course
	local filter = "if Heure_depart_reelle ~= nil and Heure_depart_reelle >= 0 and Heure_arrivee_reelle == nil then return true else return false end ";
	local rc, data = app.SendNotify('<ranking_load>', { filter = filter } );
	assert(rc and data.ranking ~= nil and app.GetNameSpace(data.ranking) == 'sqlTableGC');
	device.bib_running = data.ranking;
	device.bib_running:OrderBy('Heure_depart_reelle Asc');

	-- R�cup�ration Ranking
	local rc, data = app.SendNotify('<ranking_load>');
	assert(rc and data.ranking ~= nil and app.GetNameSpace(data.ranking) == 'sqlTableGC');
	device.ranking = data.ranking;

	-- Cr�ation des Timer attach� � la frame ...
	local mainframe = app.GetAuiFrame();

	device.tick_finished = -1;

	app.BindNotify("<bib_next>", device.OnNotifyBibNext);
	app.BindNotify("<bib_insert>", device.OnNotifyBibInsert);
	app.BindNotify("<bib_delete>", device.OnNotifyBibDelete);
	app.BindNotify("<bib_time>", device.OnNotifyBibTime);
	app.BindNotify("<passage_add>", device.OnNotifyPassageAdd);

	-- Mode Classique ...
	app.BindNotify("<best_time>", device.OnNotifyBestTime);

	app.BindNotify("<offset_time>", device.OnNotifyOffsetTimeSet);
	app.BindNotify("<run_erase>", device.OnNotifyRunErased);
	app.BindNotify("<nb_inter>", device.OnNotifyNbInter);

	-- Mode Ranking par d�faut ...
	OnModeStartlist();
	OnModeRanking();
	start_server_fp();

	-- Dossard au d�part
	local rc, bibNext = app.SendNotify("<bib_next_load>");
	if rc and type(bibNext) == 'table' then
		device.OnNotifyBibNext('<bib_next>', { bib = bibNext.bib, passage = 0});
	end
end


function device.SetStartTime()

	local tvEpreuve = device.dbTV:GetTable('Epreuve');
	if tvEpreuve == nil then return end

	local rc, data = app.SendNotify('<ranking_load>');
	assert(rc and data.ranking ~= nil and app.GetNameSpace(data.ranking) == 'sqlTableGC');
	local tRanking = data.ranking;
	
	device.dbTV:Query('Delete From Epreuve');
	tvEpreuve:RemoveAllRows();
	
	tRanking:OrderBy('Code_epreuve, Heure_depart_reelle Asc');
	local epreuvePrev = 0;
	for i=0, tRanking:GetNbRows()-1 do
		local epreuve = tRanking:GetCellInt('Code_epreuve', i, 0);
		if epreuve ~= epreuvePrev then
			tvEpreuve:GetRecord():Set('Code', epreuve);
			tvEpreuve:GetRecord():Set('Start', tRanking:GetCellInt('Heure_depart_reelle', i, 0));
			tvEpreuve:AddRow();
			epreuvePrev = epreuve;
		end
	end
	
	device.dbTV:Query('Delete From Epreuve');
	device.dbTV:TableBulkInsert(tvEpreuve);
end

-- Notification <passage_add> : Chrono Classique 
function device.OnNotifyPassageAdd(key, params)
	-- Mode Classique ...
	assert(key == '<passage_add>');

	local bib = tonumber(params.bib) or 0;
	if bib > 0 then
		local idPassage = tonumber(params.passage) or -2;
		local timePassage = tonumber(params.time) or -1;

		if idPassage == 0 and timePassage > 0 then -- Depart
			device.BibRunning(bib, timePassage);
		elseif idPassage == -1 then	-- Arriv�e
			if timePassage == chronoStatus.Abs or timePassage == chronoStatus.Dsq then
				device.BibFinished(bib,timePassage, '', '');
			end
		end
	end
end

-- Notification : Next Bib 
function device.OnNotifyBibNext(key, params)
	assert(key == '<bib_next>');

	local passage = tonumber(params.passage) or -2;
	local bib = tonumber(params.bib) or 0;
	
	if passage == 0 and bib > 0 then
		local bibNext = device.BibLoad(bib);
		if bibNext ~= nil then
			local cmd = 
			"Update Next Set Tick = '"..app.GetTickCount().."' "..
			",State = 'O' "..
			",Bib = '"..bibNext:GetCell("Dossard", 0).."' "..
			",Identity = '"..string.gsub(bibNext:GetCell("Identite", 0), "'", "''").."' "..
			",Team = '"..string.gsub(bibNext:GetCell("Club", 0),"'","''").."' ";
			device.dbTV:Query(cmd);
		end
	end
end

-- Notification : Insertion dossard � un point de passage
function device.OnNotifyBibInsert(key, params)
	assert(key == '<bib_insert>');

	local idPassage = tonumber(params.passage) or -2;
	local bib = tonumber(params.bib) or 0;
	local timePassage = tonumber(params.time) or -1;
	
	if bib > 0 then
		if idPassage == 0 and timePassage >= 0 then
			-- Dossard au D�part : Ok si pas d'heure arriv�e 
			device.BibRunning(bib);
		elseif idPassage == -1 then
			-- Dossard a l'arriv�e Abs , Abd ...
			device.BibFinished(bib);
		end
	end
end

-- Notification: Suppression dossard � un point de passage
function device.OnNotifyBibDelete(key, params)
	assert(key == '<bib_delete>');

	local idPassage = tonumber(params.passage) or -2;
	local bib = tonumber(params.bib) or 0;
	
	if bib > 0 then
		if idPassage == 0 then
			-- Suppression d'un dossard au D�part
			device.BibDelete(bib);
		elseif idPassage == -1 then
			-- Suppression d'un dossard � l'arriv�e
			device.BibRunning(bib);
		end
	end
end

-- Chargement des informations li� au dossard
function device.BibLoad(bib)
	local rc, bibLoad = app.SendNotify("<bib_load>", { bib = bib });
	if rc and type(bibLoad) == 'table' then
		return bibLoad.ranking;
	else
		return nil;
	end
end

-- Prise en compte d'un nouveau dossard en course
function device.BibRunning(bib, timeStart)
	local row = device.bib_running:GetIndexRow('Dossard', bib) or -1;
	if row < 0 then
		local bibRanking = device.BibLoad(bib);
		if bibRanking ~= nil then
			
			timeStart = timeStart or -1;
			if timeStart > 0 then
				bibRanking:SetCell('Heure_depart_reelle',0,timeStart);
			end

			device.bib_running:AddRow(bibRanking, true);
			device.bib_running:OrderBy('Heure_depart_reelle Asc');
		end
	end
end

function device.OnNotifyBibTime(key, params)
	-- for k,v in pairs(params) do
		-- adv.Alert('Key '..k..'='..tostring(v));
	-- end
	
	local idPassage = tonumber(params.passage) or -2;
	local bib = tonumber(params.bib) or 0;
	local time_net = tonumber(params.total_time) or -1;
	local rank = params.total_rank;
	local diff = params.total_diff;
	
	if idPassage == -1 then 
		-- Finish ...
		device.BibFinished(bib, time_net, rank, diff);
	elseif idPassage >= 1 then
		-- Inter 1, 2 ...
		if time_net ~= chronoStatus.Abs then
			device.BibInter(bib, idPassage, time_net, rank, diff);
		end
	end

	if device.mode ~= 'startlist' then
		-- Prise des coureurs arriv�s ou Abd ou Dsq
		local filter = '';
		if device.raceInfo.Code_manche == 1 then
			filter = "if Tps1 ~= nil and (Tps1 >0 or Tps1 == -500 or Tps1 == -800) then return true else return false end ";
		else
			filter = "if Tps ~= nil and (Tps >0 or Tps == -500 or Tps == -800) then return true else return false end ";
		end

		local rc, data = app.SendNotify('<ranking_load>', { filter = filter } );
		assert(rc and data.ranking ~= nil and app.GetNameSpace(data.ranking) == 'sqlTableGC');
		device.ranking = data.ranking;
	end

	RefreshMode();
end

-- Suppression d'un dossard en course
function device.BibDelete(bib)
	local row = device.bib_running:GetIndexRow('Dossard', bib) or -1;
	if row >= 0 then
		device.bib_running:RemoveRowAt(row);
	end
end

function device.BibFinished(bib, time_net, rank, diff)

	if time_net == nil or time_net == chronoStatus.Abs then return end 

	local row = device.bib_running:GetIndexRow('Dossard', bib) or -1;
	local bib_finished = nil;
	if row >= 0 then
		bib_finished = adv.Filter(device.bib_running, function(t,row) return tonumber(t:GetCell('Dossard',row)) == bib end);
		assert(bib_finished:GetCell("Dossard",0) == tostring(bib));
		device.bib_running:RemoveRowAt(row);
	else
		bib_finished = device.BibLoad(bib);
	end
	
	if bib_finished ~= nil and bib_finished:GetNbRows() > 0 then
		device.tick_finished = app.GetTickCount();

		rank = rank or '';

		diff = diff or '';
		if type(diff) == 'number' then
			diff = app.TimeToString(diff, '[DIFF]%xs.%2f');
		end
		
		local cmd = 
			"Update Running Set State = 'F' "..
			",Tick = '"..app.GetTickCount().."' "..
			",Bib = '"..bib_finished:GetCell("Dossard", 0).."' "..
			",Identity = '"..string.gsub(bib_finished:GetCell("Identite", 0), "'", "''").."' "..
			",Team = '"..string.gsub(bib_finished:GetCell("Club", 0),"'","''").."' "..
			",Time = '"..app.TimeToString(time_net).."' "..
			",Rank = '"..tostring(rank).."' "..
			",Diff = '"..diff.."' ";
--		adv.Alert(cmd);
		device.dbTV:Query(cmd);
	end
end

-- Notification : Nouveau Meilleur Temps
function device.OnNotifyBestTime(key, params)
	assert(key == '<best_time>');

	if params ~= nil and params.ranking ~= nil and params.ranking:GetNbRows() == 1 then
		local identity = params.ranking:GetCell("Prenom", 0):sub(1,1)..'.'..params.ranking:GetCell("Nom", 0);
		identity = string.gsub(identity, "'", "''");

		local cmd = 
			"Update Context Set Best_identity = '"..identity.."' "..
			",Best_time = '"..app.TimeToString(params.total_time).."' "..
			"Where ID = 1";
		device.dbTV:Query(cmd);
	else
		device.dbTV:Query("Update Context Set Best_identity = '', Best_time = '' Where ID = 1");
	end
end
	
function device.OnNotifyOffsetTimeSet(key, params)
	device.offset = tonumber(params.offset);
	adv.Warning('New Offset TV = '..device.offset);
	return true;
end

-- Notification : Effacement de la Manche
function device.OnNotifyRunErased(key, params)
	if device.bib_running ~= nil then
		device.bib_running:RemoveAllRows();
	end

	device.best_time = {};
	device.tick_finished = -1;

	device.dbTV:Query("Update Context Set Best_identity = '',Best_time = ''  Where ID = 1");
	device.dbTV:Query("Update Running Set State = 'C' Where ID = 1");
	device.dbTV:Query("Delete From Ranking");
end

-- Notification : Changement du nombre de temps inter
function device.OnNotifyNbInter(key, params)
	assert(key == '<nb_inter>');
	device.raceInfo.Nb_inter = params.nb;
end

-- Fermeture
function device.OnClose()
	-- Fermeture Toolbar 
	if tbNavigation ~= nil then
		local mgr = app.GetAuiManager();
		mgr:DeletePane(tbNavigation);
	end
	stop_server_fp();
end

function OnModeClear()
	device.mode = 'clear';
	modeLabel:SetLabel('clear');

	device.dbTV:Query("Update Context Set Mode = 'clear' Where ID = 1");
	RefreshMode();
end

function OnModeStartlist()
	
	device.mode = 'startlist';
	modeLabel:SetLabel('ENVOI DE LA STARTLIST');

	device.dbTV:Query("Update Context Set Mode = 'startlist', Title = '"..GetTitle().."' Where ID = 1");

	local rc, data = app.SendNotify('<ranking_load>');
	assert(rc and data.ranking ~= nil and app.GetNameSpace(data.ranking) == 'sqlTableGC');
	device.ranking = data.ranking;
	RefreshMode();
end

function GetTitle()
	if device.raceInfo.tables ~= nil then
		local tEvenement = device.raceInfo.tables.Evenement;
		if tEvenement ~= nil then
			local title = tEvenement:GetCell('Organisateur', 0);
			return string.gsub(title,"'", "''");
		end
	end
	return '';
end

function OnModeRanking()

	device.mode = 'ranking';

	if device.raceInfo.Code_manche == 1 then
		modeLabel:SetLabel('ENVOI DU CLASSEMENT');
		device.dbTV:Query("Update Context Set Mode = 'ranking', Title = '"..GetTitle().."' Where ID = 1");
	else
		modeLabel:SetLabel('ENVOI DU CLASSEMENT');
		device.dbTV:Query("Update Context Set Mode = 'ranking2', Title = '"..GetTitle().."' Where ID = 1");
	end

	device.dbTV:Query("Update Running Set State = 'C' Where ID = 1");

	local filter = '';
	if device.raceInfo.Code_manche == 1 then
		filter = "if Tps1 ~= nil and (Tps1 >0 or Tps1 == -500 or Tps1 == -800) then return true else return false end ";
	else
		filter = "if Tps ~= nil and (Tps >0 or Tps == -500 or Tps == -800) then return true else return false end ";
	end
	local rc, data = app.SendNotify('<ranking_load>', { filter = filter } );
	assert(rc and data.ranking ~= nil and app.GetNameSpace(data.ranking) == 'sqlTableGC');

	device.ranking = data.ranking;
	
	device.SetStartTime();

	RefreshMode();
end

function RefreshMode()
	-- Tri ...
	if device.mode == 'startlist' then
		-- Liste de D�part 
		if device.raceInfo.Code_manche == 1 then
			device.ranking:OrderBy('Dossard');
		else
			device.ranking:OrderBy('Rang2, Dossard');
		end
		TvSynchroStartlist();
	elseif device.mode == 'ranking' then
		-- Liste de R�sultat
		if device.raceInfo.Code_manche == 1 then
			device.ranking:OrderBy('Clt1, Dossard');
		else
			device.ranking:OrderBy('Clt, Dossard');
		end
		TvSynchroRanking();
	end
end

function TvSynchroStartlist()
	if device.ranking == nil or type(device.ranking) ~= 'userdata' then return end
	if device.dbTV == nil or type(device.dbTV) ~= 'userdata' then return end

	local tvStartlist = device.dbTV:GetTable('Startlist');
	if tvStartlist == nil then return end

	local tRanking = device.ranking;

	tvStartlist:RemoveAllRows();
	for i=0,tRanking:GetNbRows()-1 do

		tvStartlist:GetRecord():Set('ID', i+1);
		tvStartlist:GetRecord():Set('Bib', tRanking:GetCell('Dossard', i));
		tvStartlist:GetRecord():Set('Identity', string.gsub(tRanking:GetCell('Identite', i), "'", "''"));
		tvStartlist:GetRecord():Set('Team', string.gsub(tRanking:GetCell('Club', i),"'", "''"));

		tvStartlist:GetRecord():Set('Rank1', tRanking:GetCell('Clte1', i));
		tvStartlist:GetRecord():Set('Time1', tRanking:GetCell('Tps1', i));

		tvStartlist:GetRecord():Set('Rank2', tRanking:GetCell('Clte2', i));
		tvStartlist:GetRecord():Set('Time2', tRanking:GetCell('Tps2', i));

		tvStartlist:GetRecord():Set('Rank', tRanking:GetCell('Clte', i));
		tvStartlist:GetRecord():Set('Time', tRanking:GetCell('Tps', i));

		tvStartlist:GetRecord():Set('Epreuve', tRanking:GetCell('Code_epreuve', i));
		tvStartlist:GetRecord():Set('Categ', tRanking:GetCell('Categ', i));
		tvStartlist:GetRecord():Set('Sex', tRanking:GetCell('Sexe', i));
		tvStartlist:GetRecord():Set('Distance', tRanking:GetCell('Distance', i));

		tvStartlist:AddRow();
	end

	device.dbTV:Query('Delete From Startlist');
	device.dbTV:TableBulkInsert(tvStartlist);

	device.dbTV:Query("Update Startlist Set Tick = '"..app.GetTickCount().."' ");
end

function TvSynchroRanking()
	if device.ranking == nil or type(device.ranking) ~= 'userdata' then return end
	if device.dbTV == nil or type(device.dbTV) ~= 'userdata' then return end

	local tvRanking = device.dbTV:GetTable('Ranking');
	if tvRanking == nil then return end

	local tRanking = device.ranking;

	tvRanking:RemoveAllRows();
	for i=0,tRanking:GetNbRows()-1 do

		tvRanking:GetRecord():Set('ID', i+1);
		tvRanking:GetRecord():Set('Bib', tRanking:GetCell('Dossard', i));
		tvRanking:GetRecord():Set('Identity', string.gsub(tRanking:GetCell('Identite', i), "'", "''"));
		tvRanking:GetRecord():Set('Team', string.gsub(tRanking:GetCell('Club', i),"'", "''"));

		tvRanking:GetRecord():Set('Rank1', tRanking:GetCell('Clte1', i));
		tvRanking:GetRecord():Set('Time1', tRanking:GetCell('Tps1', i));

		tvRanking:GetRecord():Set('Rank2', tRanking:GetCell('Clte2', i));
		tvRanking:GetRecord():Set('Time2', tRanking:GetCell('Tps2', i));

		tvRanking:GetRecord():Set('Rank', tRanking:GetCell('Clte', i));
		tvRanking:GetRecord():Set('Time', tRanking:GetCell('Tps', i));
		
		tvRanking:GetRecord():Set('Cltc', tRanking:GetCell('Cltc', i));
		tvRanking:GetRecord():Set('Cltc1', tRanking:GetCell('Cltc1', i));		
		tvRanking:GetRecord():Set('Cltc2', tRanking:GetCell('Cltc2', i));
		
		tvRanking:GetRecord():Set('Epreuve', tRanking:GetCell('Code_epreuve', i));
		tvRanking:GetRecord():Set('Categ', tRanking:GetCell('Categ', i));
		tvRanking:GetRecord():Set('Sex', tRanking:GetCell('Sexe', i));
		tvRanking:GetRecord():Set('Distance', tRanking:GetCell('Distance', i));

		tvRanking:GetRecord():Set('Finish', tRanking:GetCellInt('Heure_arrivee_reelle', i));

		tvRanking:AddRow();
	end

	device.dbTV:Query('Delete From Ranking');
	device.dbTV:TableBulkInsert(tvRanking);

	device.dbTV:Query("Update Ranking Set Tick = '"..app.GetTickCount().."' ");
end


function start_server_fp()
    -- Définir le chemin complet du fichier .bat
    local batFilePath = "C:/skiFFS/device/FOXXPROD_SKIFFS/start_server.bat"
    
    -- Commande pour exécuter le fichier batch sans bloquer l'exécution du script
    local command = 'start "" "' .. batFilePath .. '"'

    -- Exécuter la commande (cela lancera le batch dans une nouvelle fenêtre sans bloquer)
    os.execute(command)
end


function stop_server_fp()
    -- Définir le chemin complet du fichier .bat pour arrêter le serveur
    local batFilePath = "C:/skiFFS/device/FOXXPROD_SKIFFS/stop_server.bat"
    
    -- Commande pour exécuter le fichier batch sans bloquer l'exécution du script
    local command = 'start "" "' .. batFilePath .. '"'

    -- Exécuter la commande (cela lancera le batch dans une nouvelle fenêtre sans bloquer)
    os.execute(command)
end



