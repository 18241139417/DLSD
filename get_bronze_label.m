function label = get_bronze_label(filename)
% get_bronze_label  Determine class label from WAV filename.
% Returns 'Mineralized' if filename contains 'bad' or 'mineral'
% (case-insensitive), otherwise returns 'Intact'.
% Single source of truth for both SVM and MobileNet pipelines.
    lowerName = lower(char(filename));
    if contains(lowerName, 'bad') || contains(lowerName, 'mineral')
        label = 'Mineralized';
    else
        label = 'Intact';
    end
end
