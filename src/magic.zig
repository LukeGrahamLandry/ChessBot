// TODO: auto train against the fish to find the best settings. draw avoidence, square preference, etc.
// TODO: do I want these to be runtime configurable in the ui?

// Draws are bad if you're up material but good if you're down materal. Slight preference against because that's more fun.
// TODO: if you change this go back and make sure to multiply by the right dir() when using
pub const DRAW_EVAL = 0;

// TODO: only good if there are pawns in front of you
pub const CASTLE_REWARD: i32 = 50;

// This gets optimised out if 0.
// Otherwise, super slow! Maybe because of the branch on colour for direction?
// Must be changing how it prunes cause doing bit magic for dir() is still slow.
// Tried turning off capture extend, still slower
pub const PUSH_PAWN: i8 = 0;

// TODO: better zobrist numbers. these are just [random.randint(0, 18446744073709552000) for i in range(781)].
//       can just experimentally run a bunch of games until I find the ones with least collissions?
/// Magic numbers for Zobrist hashing. I think I'm so funny.
pub const ZOIDBERG: [781]u64 = [781]u64{ 5598615492909055030, 1565257716010202786, 7778895289806082012, 1347101178074813958, 15138649586303596023, 14775177158075481006, 4041695659531758769, 11366899508225364741, 2718706818780636394, 9710610378009798328, 18077258826448370900, 13146249614797981042, 16773909782886978441, 8160725283560298457, 6610748436885286190, 14062326007262021723, 12930492712839037120, 9783724591270309941, 10427213058015952869, 14252491382558608922, 13593733992569002782, 9929781383795191267, 6997593653909912326, 17424294281229971096, 11891411391218781449, 4371604055490869614, 7565561010104679175, 9610006078364530569, 5992396257362946994, 2269290236823850428, 2015701045378955881, 14698080585417279410, 12571565151323357335, 15264554964844286737, 6138065523868107132, 2277853585678815822, 1553848572684494996, 3093754585076481336, 11708621162498616665, 9316547340517350746, 10634911878772413473, 3853778475814496468, 16634749351362366216, 15496349965793237543, 7696834967591209203, 7689449390414480793, 10979395340484779339, 11542152163282818712, 6248099425865402577, 771410749706907323, 872681269086325155, 17636603743025282056, 10784730005903881950, 3856906909534530258, 12020058320254472276, 17187940234837102440, 5337742374245512938, 13216262310417132096, 17455799436765003490, 8274219331195103460, 1337622522872188621, 1887908522217155927, 8426452519880811279, 5903760473457834988, 13319105869966305515, 7409144757516146652, 1166798139345297895, 15328664677858931770, 14860749852685102651, 9947960646350000767, 543855426880617764, 9781169701678014495, 16715048278511143693, 13313150936339193474, 10877939165418153341, 15335492262471442367, 13247950824098319602, 17550193266429906723, 4777121574121839891, 9002228462076563902, 12692866794855375231, 14855269373282354404, 17858027138871307770, 5749577842580555282, 5398773585852040503, 10192406742000480787, 11689920782225208855, 9028312936756099173, 15715596324762826137, 11535727224369692645, 4800206340480596249, 3591324267418799484, 13224661274394827286, 10107265078072219346, 2670276085994480653, 11367201435053300926, 17694622048371160812, 11379684827961798521, 1920585146577862777, 17421939205811585423, 13481721227139172573, 13826809301822990088, 5006467228004806896, 16222755813399364752, 4206096510455267069, 10332706641841486173, 4518688770715323672, 6322249860803473089, 15766082888205947870, 9414520085419069087, 6047908954197269083, 15361373766074266645, 17967213786589771332, 16722838799548402972, 11244258750782658905, 1369438950873092520, 8104224952138813564, 8473773625312107394, 7466517472063944210, 17987605077926857179, 6152215390501077438, 14904436788030891235, 3696210575851166512, 10280006184525206582, 17214022492850689653, 6345097552159777845, 11739653035220257777, 11323517179570349197, 16496069030078531214, 17047194471471024036, 2459368276358491668, 52190635528076101, 11550581753027987628, 8875999670876496992, 3629429291689553426, 4984065552878146041, 7877339120740039416, 8184531828724923900, 12051350703525088397, 9726565056345351553, 8496361117916712111, 2243470302700260999, 14042847418824124792, 6286462346002454648, 7393489683951631969, 3085492272491850406, 6773562087349882796, 14837179725680465301, 367710167661264527, 17835878875135951128, 5280909317902140622, 9108895277111172224, 5633977804003535529, 16832921362549299905, 17990553779612967884, 11724995919142134978, 5978884012905461335, 299897893700815094, 8337202575001451864, 8827481704759976681, 9140517987343102318, 2421893200042575330, 9993057492246219331, 18054394134007735157, 10096010804327478335, 10425054932417881645, 9466945323438438209, 16167014562997989554, 3538357555187600094, 4702893550117850922, 15485965658014649394, 2494289217374407362, 14248351942790362109, 5434629673616201646, 17111752303789365623, 3047565666196053757, 5596921110275228522, 9889582850646368964, 18375597815453914621, 2351771419860119230, 17194895570366677862, 2405266551137306238, 1222001849263656096, 16013606783637298124, 45030028133266771, 15156652984415834073, 13939014562271437677, 563101551705888150, 5966418394317780596, 16841491928901199393, 12864880635045252120, 1407344846717525832, 7090034033940119368, 1154196364389150887, 5892137042373033260, 14330835105982168957, 2935336844288234027, 10029495770870244811, 6901024848080825173, 16223574071310124701, 7106865160857475177, 10722385066510021063, 14402416891963269258, 11313611871544177615, 12851227362356341429, 9960759007815846117, 8566017280030498794, 3517749900262573286, 8019120001660526111, 7220756622584670191, 13538538419599041965, 17977741086728409010, 16839121775099923585, 11259166000271263409, 10719575411075283960, 2350039283449807520, 8075839901081851455, 13245356483348377227, 16423862603146177811, 16149913429574283107, 7163966064878425650, 8700216792211880458, 10173061306753098948, 3876358484697990516, 978480050048483864, 11742288083703911489, 17369088418376800819, 10393355754635391736, 6590110609413187408, 12911494489771299979, 14120570104297256663, 4042371614498812991, 6298843607169781620, 4110360286231076343, 2970024110454101533, 7547046866952670891, 14060753886659576329, 8005586922214050398, 15779531888663611876, 7270076319955991276, 4740907485192436809, 12187234397340602065, 36301914822683030, 8281682321639962596, 16375686388225353499, 1128962937155124473, 8505272011383374913, 11716103983790754724, 12992514182154048298, 3646849940350847550, 1860162469518625377, 1890327112767372416, 4043857367769604787, 10586433960449152021, 4237594300185443895, 11923417244849168206, 12558726657971088752, 16446151499688588195, 243480636392997513, 2115168058022331409, 14569878107592083568, 8248893095018681657, 2100235417492620576, 13284466457557502041, 17376919081172377608, 8535541661258884723, 1792730821027383658, 8347695797306878342, 4240186993047432507, 7583729635783860023, 15692158854216491727, 6885863107938146516, 6411019515912750276, 17941726373198496560, 9971220525454862128, 8692539804856397464, 7772770746346631865, 2656302853390710200, 16703793241631489367, 17335061057504139877, 14018840898577334231, 4264333281550392332, 9757781604362865474, 3049757487568222345, 16471168939884758917, 9266463123712234757, 13370922884513956705, 6678633115351531218, 11509724666684596332, 10473502119507399670, 8367551984457658854, 4208335088321520655, 6269151632359007704, 11832021909846974965, 10958662257194534832, 12902958423078613245, 3733571931047923194, 17131736982022010427, 15352443562345265295, 16227166837149828589, 16005429014234831255, 13586202962501126326, 8395736447617327266, 14364381048178450205, 10166687318667295404, 14963477542732463818, 10557559822267207813, 6756824117905282899, 3565866914005352834, 10124736492299010578, 5458971358772222955, 12188778359580988213, 11285488784563380891, 2108960006372271784, 5179309385672330668, 1895407755826105625, 2767632386068695913, 11611861519476105649, 17520056056171238381, 2269814474943787904, 12274178452939488292, 5856218406697633445, 12912508456051329401, 14288586900434029624, 3420635983284003900, 9147213917400057837, 347061849464168043, 11157597454355532891, 4205170541419329306, 11280411699301681685, 10061240631418450574, 17337472137755808809, 7357103801953271316, 13245970167362283847, 4207348889343820398, 4521243171480467224, 14337387315155384651, 17239297645419885606, 3648294621481940656, 4880982499632125234, 9457428875124222648, 14492322830135365310, 17876304125493558640, 345162038701380667, 82560211485114296, 13542947252306031685, 8567342990245928236, 7467108255310320341, 7086193676515296859, 14803750014091508957, 8108168237601750442, 5439178302399066776, 6912214830920727771, 3270633739297493614, 16733089641609475273, 11844670759273651036, 18158165348051202356, 8110237775482396038, 2331873935190017740, 13539311079966622328, 8831665358525705149, 1327427605283930683, 14115581034220945737, 16290466693024083780, 9409338938870798460, 6696083314671159890, 12851474297145011095, 17840125468804808015, 10091411345513023157, 16316516837152150166, 12425953926220181392, 32176575048862270, 2255676359747525330, 13285871491254976157, 2645809786386856371, 4888590814916234376, 13199239154695862891, 2019652365339818336, 2763491331439141872, 15279136802937022001, 2323643072842024256, 8704706699873761011, 5421935401867286909, 14862060138928116214, 16984545380516617722, 3787912953589205580, 9993119759281541933, 1511853199448564817, 5945221155309074608, 2929220767670592390, 9201099685904977310, 15907096079943628346, 7029546540292983302, 12781393966326229711, 15932619392660483924, 8686763591529590196, 9775658809301485481, 16322582377871275894, 13700497666266395831, 3404143362266289269, 8331744873719623654, 2337680994177311512, 8114064338835222089, 12878529862180228421, 6687783119483336031, 11194642992488877127, 17128783764823519941, 2252279191692527143, 17746574741207838148, 6957276006765311726, 3791096195527825561, 5696200255905320202, 18445410632168925445, 13415551646633706371, 6569196320015515045, 13151057030232953218, 12573735461824190674, 1963523554984651279, 9898398610911643481, 5832115079803947997, 4783179538440440740, 527922023194223241, 4516261772704253219, 13623483896589694839, 3783367098458020765, 11394981928164776600, 521781993913011887, 17991271948707773800, 12901797080736773226, 6264996724366278271, 7389207414032505411, 9165462581953013301, 6269629353515459638, 7656064776504301094, 12745652004870265819, 16742339754771744580, 14958744708760644561, 17801954145430198011, 13194212518487780380, 641968814767948702, 18395498757152727207, 7577298454446657287, 5412155884447713590, 3386133157114613724, 11830542157637062864, 12691991016565730908, 12214162897404942833, 781003694951659901, 11556387628399324609, 10436448605813125158, 2627174669864335908, 13089464616208720478, 9839887405619652604, 13527742366776183490, 3727899996258043241, 12602681164089178091, 2567045108276584717, 15372017003650419209, 6866476299847557785, 2491517172098694807, 6626092153628915640, 648675839416678706, 10547150654641589625, 1954572077163786897, 8587954570689057852, 12830621910088512039, 13394934631898844959, 18361922468766040989, 87218782865130502, 5280118499645181301, 7813563596930301418, 6398928935950669268, 7799420627966707824, 10476768614543357206, 6103781042292539282, 17587635532978003059, 2039159461096841240, 8655073352905012226, 15240489655350518700, 2238905460987577299, 7322107214523437719, 10069509019385340281, 1795749876899347335, 3365664193423364593, 12336390487490829743, 6204706062153034574, 16906865320748068441, 12275741362870773907, 8278660476586935273, 1472832589185990872, 8032391584435064750, 1389812041995734162, 4013864953270193476, 12592358254219666447, 12274139779490352282, 3897667988188008560, 7397697517892490556, 9025718192999516604, 5353422228477299617, 197558909219964443, 7813524593598424810, 15011841506353581772, 11432262534907066953, 8850777938612828219, 5155443261576666923, 404530154215616373, 3023690474041193337, 7786157614068457492, 9099005819707560806, 6455711977266650629, 7324397869015083365, 12657348372247637816, 16012839441391230142, 16625545870069633379, 9693371561102745214, 2347470318589897006, 14149816824050568217, 14666239872347763159, 10108026281944428975, 14533439101978297732, 9974520966916108946, 10710058112218121634, 18401729618298682094, 12593173751652738846, 12307949772114328179, 16750132735248164734, 15741013829372694523, 3023675379237578395, 875698831019091274, 7192276908951328981, 14230307009752726146, 16015492849886448746, 10842979855440951183, 11865930023419452361, 6963169056145808076, 1031754426805254016, 4548199034164209300, 17726191182109717083, 1711601737622928692, 16384716896225252824, 16343601590869479058, 9153630623006817736, 17615187307772792759, 5063761624900242630, 16823954720162636285, 8602770192792860797, 1093937494767707494, 110456470130663783, 17584953572247123366, 11510491646805557005, 9639192937022424025, 8020756895539760486, 13012301599209384628, 4497673208710175038, 14946750969385896196, 12335081362627851899, 7314941954121630532, 14312546508047973307, 2611331793796093580, 12043484076813579663, 3451260235448188793, 14618858292604683913, 4370712681428492868, 13365800602770087366, 14487599500963942146, 4367060225274510486, 6596449284275611443, 1369568030058427466, 13248055113128944132, 11569583868535686163, 17078405270919835025, 10542586771895886330, 10119033512531345705, 12863490124882575607, 16055603946610065719, 9352517760489771015, 9822231751498389067, 14500969307085209335, 8652151769606064594, 1101867165633925308, 17861058338539905807, 8145628351149934204, 4018056103981609753, 11259146570864375232, 13929486496932754162, 3475766541212813645, 16816900459458327092, 8338648400721655319, 6000082595187195174, 5289839003196741415, 13489676940680392014, 7478481086789484855, 17042317845858292104, 15325710437053864002, 4503475327317879759, 14921851005031693399, 436009653300133086, 13106071483467496745, 15065058066332285811, 14290540824188778781, 8451729328184745671, 10249449001518588446, 3376156699006995502, 6229520583265198063, 17635201726708842871, 17123128527814559058, 2815205868810807963, 14923563696141648367, 7581159670483276506, 8095726333909679148, 9471511101509256553, 16540548833513052568, 4627840358657904827, 6683867631593879392, 5704080080338758244, 6434264290391774492, 13790460411924089414, 17649773760726969401, 7385639376967754289, 15914427018124390173, 18032228878168334157, 1065986073277487074, 17679964666470759032, 1749373702403537727, 6050003787189808167, 13527685854033806309, 17779248232539848106, 5307298477079661751, 6283233064840206744, 9201203479341808810, 8760293260261392125, 8234313091517288016, 12469453615563388473, 13051689926623524297, 11270385357769659918, 17221330862946117799, 7351918222226834127, 5972675838738523104, 11908104961979579983, 7520676709145665181, 10392680873149573878, 8321941162754322673, 10037711224810567930, 2883677038204307758, 3474504033792852432, 9575703095532708805, 15217915257541247856, 17429672645998939506, 6847160181735400636, 16053055009842585547, 7418613489717574003, 8674883665072179841, 616098158442150608, 3469248923432069480, 5241969512174682049, 3697313590124580341, 14995842010466278205, 7534171224686586508, 11827180498117056438, 6143309995696273824, 516754328761326109, 14125583233140909450, 2568411222348310095, 5731231386680328341, 15274831969812297841, 3027877598610838497, 686239410154505789, 7060191251702246781, 804509610792638718, 9610039605910793939, 12657660455815945253, 10761137615479238759, 13484078785516940112, 2282595688276438221, 14617093520339168654, 10119543887064906856, 9267827299333800141, 5561170218644667136, 16863130416734854735, 5278338241334034822, 8437022849285819587, 14392138276289393992, 16076437954167110444, 8425454744237486313, 3508155582762067504, 392706342254234066, 5530068962590063161, 10120382826303148809, 9671712042532958422, 2738601114797307698, 10413289252702352618, 8988575960058306227, 15455300891212116758, 14360953982094508857, 251006049041304999, 636901548256693660, 11546671369589134187, 13086153742895830345, 17051303464347655041, 5160538320261565785, 10229900433831060439, 3290018082179640808, 16582715796437973559, 3975697931905338585, 6326241586893185277, 18117407276743355335, 889346337383521783, 9596645547199384718, 16362885301339138648, 13336420809883899944, 11867923757060724636, 8685498392133023817, 12007670050601278978, 561302346079888369, 14250208293956075839, 2738877103464816111, 2717644735647008454, 2022794766758431444, 13436441891133975267, 13892295781096270537, 10903323859918030260, 3594136652719860985, 15426068620830775098, 8941039976339679658, 5076401837933995730, 4352196129424334577, 17841952487786221451, 11752738666283840864, 12712702889424038593, 8782722135542046799, 18308130129092420679, 12013420784661902895, 17353126924045537131, 8835894390067675523, 8641701396586322857, 14591158550812871746, 9523426188924049823, 13618406652649880126, 17431379074325943221, 3628818956715808139, 15522196296703315415, 8752213567158961907, 16969339941364204831, 4466148909033109527, 2874706365906430986, 977730850973984046, 4965287520840533798, 8814700552539543747, 13583755784602410322, 14956220786219187620, 2470996473737545274, 748277977683704023, 14010627905999049786, 8432276978930798605, 13269234668320571721, 7219960718261171936, 16196844553299120035, 12085837484422377930, 5237354294282454880, 11139544441610444840, 2376925713178459783, 9306042269586187683, 974171406828591423, 14184695226401463692, 14038700854043802970, 4698381811245319223, 9578648001284911629, 9078910151786834828, 6745600108235817439, 15101569689757814111, 10572626177235075480, 11226818475533710321, 6136542879872929699, 15468216764965037695, 11777556528497016833, 1789712296217313915, 14038434134583887256, 9910130836898841934, 2098110052138615585, 3602417724085806736, 17584839194975363740 };
pub const ZOID_TURN_INDEX: usize = 0;
pub const ZOID_FRENCH_START: usize = 1;
pub const ZOID_CASTLE_START: usize = 9;
pub const ZOID_PIECE_START: usize = 13;

test "do you are have random" {
    var failed = false;
    for (ZOIDBERG) |number| {
        var count: usize = 0;
        for (ZOIDBERG) |check| {
            if (check == number) count += 1;
        }
        if (count != 1) {
            @import("std").debug.print("({} -> {})\n", .{ number, count });
            failed = true;
        }
    }
    try @import("std").testing.expect(!failed);
}
