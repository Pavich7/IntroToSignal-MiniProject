function dtmf_dashboard
% MATLAB version of dtmf_dashboard.py. Run: dtmf_dashboard
FS = 16000; N = 1024; BAUD = 1000000;
magic = uint8('S3A2'); frameSize = 8 + 2*N;
window = 0.5 - 0.5*cos(2*pi*(0:N-1)'/(N-1));
freq = (0:N/2)'*FS/N;
lowFreq = [697 770 852 941];
highFreq = [1209 1336 1477 1633];
keys = ['123A'; '456B'; '789C'; '*0#D'];

port = []; rx = uint8([]); number = ''; expectedLength = [];
completed = false; history = strings(0,1); lastKey = ''; reported = false;

fig = uifigure('Name','ESP32 DTMF Detector','Position',[100 100 1200 700]);
fig.CloseRequestFcn = @closeApp;
main = uigridlayout(fig,[2 2]);
main.RowHeight = {45,'1x'}; main.ColumnWidth = {300,'1x'};
bar = uigridlayout(main,[1 5]); bar.Layout.Row = 1; bar.Layout.Column = [1 2];
bar.ColumnWidth = {230,90,100,'1x',260};
portList = uidropdown(bar,'Items',availablePorts(),'Editable','on');
refresh = uibutton(bar,'Text','Refresh','ButtonPushedFcn',@refreshPorts); %#ok<NASGU>
connectButton = uibutton(bar,'Text','Connect','ButtonPushedFcn',@toggleConnection);
connectionLabel = uilabel(bar,'Text','Disconnected');
uilabel(bar,'Text',sprintf('%d baud | %d Hz | FFT %d',BAUD,FS,N));

left = uigridlayout(main,[8 1]); left.Layout.Row = 2; left.Layout.Column = 1;
left.RowHeight = {35,130,65,70,25,50,35,'1x'};
uilabel(left,'Text','DTMF keypad','FontSize',18,'FontWeight','bold');
pad = uigridlayout(left,[4 4]);
pad.RowHeight = {30,30,30,30}; pad.ColumnWidth = {55,55,55,55};
buttons = gobjects(4,4);
for r = 1:4
    for c = 1:4
        buttons(r,c) = uibutton(pad,'Text',keys(r,c),'Enable','off');
        buttons(r,c).Layout.Row = r; buttons(r,c).Layout.Column = c;
    end
end
detectedLabel = uilabel(left,'Text','Detected key: -','FontSize',24,'FontWeight','bold');
numberLabel = uilabel(left,'Text','Current number: Waiting for 0','FontSize',15);
countLabel = uilabel(left,'Text','0 digits');
messageLabel = uilabel(left,'Text','Waiting for ESP32');
uibutton(left,'Text','Clear number','ButtonPushedFcn',@clearNumber);
historyLabel = uitextarea(left,'Value',{'Completed numbers:'},'Editable','off');

ax = uiaxes(main); ax.Layout.Row = 2; ax.Layout.Column = 2;
line = plot(ax,freq,zeros(size(freq))); grid(ax,'on');
xlim(ax,[0 2000]); ylim(ax,[0 1600]);
xlabel(ax,'Frequency (Hz)'); ylabel(ax,'Magnitude (ADC counts)');
title(ax,'Real-time FFT Spectrum');

% Poll without blocking the UI. The callback also resynchronizes after noise.
pollTimer = timer('ExecutionMode','fixedSpacing','Period',0.01, ...
    'BusyMode','drop','TimerFcn',@readSerial);
start(pollTimer);

    function names = availablePorts()
        names = cellstr(serialportlist('available'));
        if isempty(names), names = {'COM7'}; end
    end

    function refreshPorts(~,~)
        current = portList.Value;
        names = availablePorts();
        if ~any(strcmp(names,current)), names = [names {current}]; end
        portList.Items = names;
        portList.Value = current;
    end

    function toggleConnection(~,~)
        if ~isempty(port)
            port = []; rx = uint8([]);
            connectButton.Text = 'Connect'; connectionLabel.Text = 'Disconnected';
            messageLabel.Text = 'Disconnected'; return
        end
        try
            port = serialport(portList.Value,BAUD,'Timeout',0.1);
            flush(port); rx = uint8([]);
            lastKey = ''; reported = false;
            connectButton.Text = 'Disconnect';
            connectionLabel.Text = ['Connected: ' char(portList.Value)];
            messageLabel.Text = 'Receiving audio...';
        catch err
            port = [];
            uialert(fig,err.message,'Connection error');
        end
    end

    function readSerial(~,~)
        if isempty(port) || ~isvalid(fig), return; end
        try
            count = port.NumBytesAvailable;
            if count > 0, rx = [rx reshape(read(port,count,'uint8'),1,[])]; end %#ok<AGROW>
        catch err
            messageLabel.Text = ['Serial read error: ' err.message];
            return
        end
        try
            while true
                startIndex = strfind(rx,magic); %#ok<STRIFCND>
                if isempty(startIndex)
                    rx = rx(max(1,numel(rx)-2):end); break
                end
                rx = rx(startIndex(1):end);
                if numel(rx) < frameSize, break; end
                frame = rx(1:frameSize); rx = rx(frameSize+1:end);
                sequence = double(frame(5)) + 256*double(frame(6)) + ...
                    65536*double(frame(7)) + 16777216*double(frame(8));
                bytes = double(frame(9:end));
                samples = bytes(1:2:end)' + 256*bytes(2:2:end)';
                processFrame(samples,sequence);
            end
        catch err
            messageLabel.Text = ['Processing error: ' err.message];
            stop(pollTimer);
        end
    end

    function processFrame(samples,sequence)
        x = (double(samples(:))-mean(samples)).*window;
        spectrum = abs(fft(x))/sum(window);
        spectrum = spectrum(1:N/2+1);
        spectrum(2:end-1) = 2*spectrum(2:end-1);
        line.YData = spectrum;
        title(ax,sprintf('Real-time FFT Spectrum | Block %u',sequence));
        key = detectKey(spectrum);
        if isempty(key), detectedLabel.Text = 'Detected key: -';
        else, detectedLabel.Text = ['Detected key: ' key]; end
        for i = 1:numel(buttons), buttons(i).BackgroundColor = [0.96 0.96 0.96]; end
        if ~isempty(key)
            [keyRow,keyCol] = find(keys == key,1);
            buttons(keyRow,keyCol).BackgroundColor = [0.73 0.90 1];
        end
        addDigit(key);
    end

    function key = detectKey(spectrum)
        key = '';
        low = arrayfun(@(f) peak(f,spectrum),lowFreq);
        high = arrayfun(@(f) peak(f,spectrum),highFreq);
        [lowBest,li] = max(low); [highBest,hi] = max(high);
        lowSorted = sort(low,'descend'); highSorted = sort(high,'descend');
        if lowBest < 40 || highBest < 40 || ...
                lowBest < 1.35*lowSorted(2) || ...
                highBest < 1.35*highSorted(2) || ...
                highBest/lowBest < 0.1 || highBest/lowBest > 10
            return
        end
        key = keys(li,hi);
    end

    function value = peak(f,spectrum)
        % Python's round(freq/BIN_HZ) gives a zero-based FFT bin.
        bin = round(f/(FS/N)) + 1;
        value = max(spectrum(bin-1:bin+1));
    end

    function addDigit(key)
        if isempty(key), lastKey = ''; reported = false; return; end
        if ~strcmp(key,lastKey), lastKey = key; reported = false; end
        if reported, return; end
        reported = true;
        if ~isstrprop(key,'digit'), return; end
        if isempty(number) || completed
            if key ~= '0', return; end
            number = '0'; expectedLength = []; completed = false;
        else
            number = [number key];
        end
        if numel(number) == 2
            if any(strcmp(number,{'02','03','04','05','07'}))
                expectedLength = 9;
            elseif any(strcmp(number,{'06','08','09'}))
                expectedLength = 10;
            end
        end
        numberLabel.Text = ['Current number: ' number];
        if isempty(expectedLength), countLabel.Text = sprintf('%d digits',numel(number));
        else, countLabel.Text = sprintf('%d / %d digits',numel(number),expectedLength); end
        if ~isempty(expectedLength) && numel(number) == expectedLength
            completed = true; history(end+1,1) = string(number);
            historyLabel.Value = [{'Completed numbers:'}; cellstr(history(max(1,end-5):end))];
            messageLabel.Text = 'Number complete';
        elseif isempty(expectedLength)
            messageLabel.Text = 'Waiting for recognized Thai prefix';
        else
            messageLabel.Text = 'Receiving number...';
        end
    end

    function clearNumber(~,~)
        number = ''; expectedLength = []; completed = false;
        lastKey = ''; reported = false;
        numberLabel.Text = 'Current number: Waiting for 0';
        countLabel.Text = '0 digits'; messageLabel.Text = 'Waiting for DTMF';
    end

    function closeApp(~,~)
        stop(pollTimer); delete(pollTimer); port = [];
        delete(fig);
    end
end
